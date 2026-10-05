@testable import Bitkit
import Combine
import Paykit
import SwiftUI
import XCTest

@MainActor
final class ContactsListViewTests: XCTestCase {
    func testCancellationDoesNotShowLoadErrorOrMarkIntroSeen() async throws {
        let cases: [(leaveScreen: Bool, error: Error?)] = [
            (false, CancellationError()),
            (true, TestError.offline),
            (true, nil),
        ]
        for (leaveScreen, error) in cases {
            let manager = SuspendedContactsListManager(error: error)
            let app = AppViewModel()
            snapshotAppDefaultsDomain()
            app.hasSeenContactsIntro = false
            ToastWindowManager.shared.hideToast()
            var shownToasts: [Bitkit.Toast] = []
            let subscription = ToastWindowManager.shared.$currentToast.compactMap { $0 }.sink { shownToasts.append($0) }
            defer { subscription.cancel() }
            let window = host(manager, app: app)
            defer { close(window) }

            await fulfillment(of: [manager.started], timeout: 3)
            if leaveScreen {
                window.rootViewController = UIHostingController(rootView: Color.black)
                try await Task.sleep(for: .milliseconds(100))
            }
            manager.resume()
            await fulfillment(of: [manager.finished], timeout: 3)
            try await Task.sleep(for: .milliseconds(100))

            XCTAssertTrue(shownToasts.isEmpty, "Cancelled loads must not report a failure after leaving Contacts")
            XCTAssertFalse(app.hasSeenContactsIntro)
            XCTAssertEqual(manager.contacts.count, 1)
            if leaveScreen {
                XCTAssertTrue(manager.wasCancelled)
            }
        }
    }

    func testActiveLoadFailureStillShowsErrorWithExistingContacts() async throws {
        snapshotAppDefaultsDomain()
        let manager = SuspendedContactsListManager(error: TestError.offline)
        let app = AppViewModel()
        app.hasSeenContactsIntro = false
        ToastWindowManager.shared.hideToast()
        let toastShown = expectation(description: "Contacts load error toast")
        var shownToast: Bitkit.Toast?
        let subscription = ToastWindowManager.shared.$currentToast.compactMap { $0 }.sink { toast in
            shownToast = toast
            toastShown.fulfill()
        }
        defer {
            subscription.cancel()
            ToastWindowManager.shared.hideToast()
        }
        let window = host(manager, app: app)
        defer { close(window) }
        await fulfillment(of: [manager.started], timeout: 3)
        manager.resume()
        await fulfillment(of: [manager.finished, toastShown], timeout: 3)

        XCTAssertEqual(shownToast?.title, t("contacts__error_loading"))
        XCTAssertEqual(shownToast?.description, TestError.offline.localizedDescription)
        XCTAssertTrue(app.hasSeenContactsIntro)
        XCTAssertEqual(manager.contacts.count, 1)
    }

    func testEmptyLoadErrorShowsInlineRetryAndRecovers() async throws {
        snapshotAppDefaultsDomain()
        let errorPresented = expectation(description: "Inline contacts load error")
        let recovered = expectation(description: "Retry recovered contacts")
        let source = RecoveringContactRecords()
        let manager = ContactsManager(contactRecords: { try await source.load() })
        let app = AppViewModel()
        app.hasSeenContactsIntro = false
        ToastWindowManager.shared.hideToast()
        let errorSubscription = manager.$loadErrorMessage.compactMap { $0 }.sink { message in
            XCTAssertEqual(message, "Contacts unavailable")
            errorPresented.fulfill()
        }
        let contactsSubscription = manager.$contacts.filter { !$0.isEmpty }.sink { _ in recovered.fulfill() }
        defer {
            errorSubscription.cancel()
            contactsSubscription.cancel()
            ToastWindowManager.shared.hideToast()
        }
        let window = host(manager, app: app)
        defer { close(window) }
        await fulfillment(of: [errorPresented], timeout: 3)
        try await Task.sleep(for: .milliseconds(150))
        window.rootViewController?.view.layoutIfNeeded()
        XCTAssertTrue(manager.contacts.isEmpty)
        XCTAssertFalse(manager.isLoading)
        XCTAssertNil(ToastWindowManager.shared.currentToast)
        XCTAssertFalse(app.hasSeenContactsIntro)
        let retry = try XCTUnwrap(accessibilityElement("ContactsRetry", in: XCTUnwrap(window.rootViewController?.view)))
        XCTAssertTrue(retry.accessibilityActivate(), "Activate the same Retry action a user taps")
        await fulfillment(of: [recovered], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.contacts.map(\.displayName), ["Recovered contact"])
        XCTAssertTrue(manager.hasLoaded)
        XCTAssertFalse(manager.isLoading)
        XCTAssertNil(manager.loadErrorMessage)
        XCTAssertTrue(app.hasSeenContactsIntro)
    }

    private func accessibilityElement(_ identifier: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ element: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
            if (element as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier {
                return element
            }
            if let view = element as? UIView {
                for child in view.subviews {
                    if let found = find(child) { return found }
                }
            }
            let count = element.accessibilityElementCount()
            if count > 0, count < 500 {
                for index in 0 ..< count {
                    if let child = element.accessibilityElement(at: index) as? NSObject, let found = find(child) {
                        return found
                    }
                }
            }
            return nil
        }
        return find(root)
    }

    private func host(_ manager: ContactsManager, app: AppViewModel) -> UIWindow {
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky" + String(repeating: "z", count: 52)
        let view = ContactsListView()
            .environmentObject(app)
            .environmentObject(NavigationViewModel())
            .environmentObject(profile)
            .environmentObject(manager)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private enum TestError: LocalizedError {
        case offline
        var errorDescription: String? { "Contacts unavailable" }
    }
}

@MainActor
private final class SuspendedContactsListManager: ContactsManager {
    let started = XCTestExpectation(description: "Contacts load started")
    let finished = XCTestExpectation(description: "Contacts load finished")
    private let error: Error?
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var wasCancelled = false

    init(error: Error?) {
        self.error = error
        (stream, continuation) = AsyncStream<Void>.makeStream()
        super.init()
        let key = "pubky" + String(repeating: "y", count: 52)
        contacts = [PubkyContact(
            publicKey: key,
            profile: PubkyProfile(publicKey: key, name: "Contact", bio: "", imageUrl: nil, links: [], status: nil)
        )]
    }

    func resume() {
        continuation.finish()
    }

    override func loadContacts(for publicKey: String) async throws {
        started.fulfill()
        defer { finished.fulfill() }
        for await _ in stream {}
        wasCancelled = Task.isCancelled
        if let error { throw error }
    }
}

private actor RecoveringContactRecords {
    private var attempts = 0

    func load() throws -> [Paykit.ContactRecord] {
        attempts += 1
        if attempts == 1 {
            throw NSError(domain: "ContactsRetryTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Contacts unavailable"])
        }
        return [Paykit.ContactRecord(
            publicKey: "pubky" + String(repeating: "y", count: 52), receiverPaths: [PaykitReceiverPath.wallet],
            label: "Recovered contact", profile: nil, profileFetchedAt: nil,
            createdAt: "2026-10-05T00:00:00Z", updatedAt: "2026-10-05T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )]
    }
}
