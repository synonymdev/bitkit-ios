@testable import Bitkit
import Combine
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
