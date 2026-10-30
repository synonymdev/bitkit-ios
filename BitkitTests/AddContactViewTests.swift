@testable import Bitkit
import SwiftUI
import Vision
import XCTest

@MainActor
final class AddContactViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
    }

    func testProfileAndSaveAppearBeforePaymentEndpointLookupCompletes() async throws {
        let started = expectation(description: "Endpoint lookup starts")
        let finished = expectation(description: "Endpoint lookup returns")
        var continuation: CheckedContinuation<Bool, Never>?
        let window = host { _ in
            started.fulfill()
            let result = await withCheckedContinuation { continuation = $0 }
            finished.fulfill()
            return result
        }
        defer { close(window) }
        await fulfillment(of: [started], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))

        let pendingLabels = try renderedLabels(window, name: "Profile while endpoint lookup is pending")
        XCTAssertTrue(pendingLabels.contains("alice"), "Missing profile: \(pendingLabels)")
        XCTAssertTrue(pendingLabels.contains(t("common__save").lowercased()), "Missing Save: \(pendingLabels)")
        XCTAssertFalse(pendingLabels.contains(t("common__pay").lowercased()))

        continuation?.resume(returning: true)
        await fulfillment(of: [finished], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        let readyLabels = try renderedLabels(window, name: "Pay after endpoint lookup succeeds")
        XCTAssertTrue(readyLabels.contains(t("common__pay").lowercased()), "Missing Pay: \(readyLabels)")
    }

    func testEndpointFailureKeepsContactPreviewVisible() async throws {
        let attempted = expectation(description: "Endpoint lookup fails")
        let window = host { _ in
            attempted.fulfill()
            throw TestError.offline
        }
        defer { close(window) }
        await fulfillment(of: [attempted], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        let labels = try renderedLabels(window, name: "Contact after failed endpoint lookup")
        XCTAssertTrue(labels.contains("alice"), "Missing profile: \(labels)")
        XCTAssertTrue(labels.contains(t("common__save").lowercased()), "Missing Save: \(labels)")
        XCTAssertFalse(labels.contains(t("common__pay").lowercased()))
    }

    func testLeavingPreviewCancelsEndpointTaskEvenWhenReadReturnsLate() async throws {
        let started = expectation(description: "Endpoint lookup starts")
        let finished = expectation(description: "Non-cancellable lookup returns")
        var continuation: CheckedContinuation<Bool, Never>?
        var wasCancelled = false
        let window = host { _ in
            started.fulfill()
            let result = await withCheckedContinuation { continuation = $0 }
            wasCancelled = Task.isCancelled
            finished.fulfill()
            return result
        }
        defer { close(window) }
        await fulfillment(of: [started], timeout: 3)
        window.rootViewController = UIHostingController(rootView: Color.black)
        try await Task.sleep(for: .milliseconds(100))
        continuation?.resume(returning: true)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(wasCancelled)
        let labels = try renderedLabels(window, name: "Retired contact preview")
        XCTAssertFalse(labels.contains(t("common__pay").lowercased()))
    }

    private func host(endpoint: @escaping (String) async throws -> Bool) -> UIWindow {
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky" + String(repeating: "y", count: 52)
        let view = AddContactView(publicKey: PreviewContactsManager.publicKey, loadPaymentEndpoint: endpoint)
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel(currencyService: OfflineCurrencyService()))
            .environmentObject(NavigationViewModel())
            .environmentObject(PreviewContactsManager() as ContactsManager)
            .environmentObject(profile)
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(SheetViewModel())
            .environmentObject(WalletViewModel())
            .environment(HwWalletManager())
            .preferredColorScheme(.dark)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func renderedLabels(_ window: UIWindow, name: String) throws -> [String] {
        let view = try XCTUnwrap(window.rootViewController?.view)
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string.lowercased() } ?? []
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private enum TestError: Error {
        case offline
    }
}

@MainActor
private final class PreviewContactsManager: ContactsManager {
    static let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    override func fetchContactProfile(publicKey: String, includePlaceholder: Bool, retryTransient: Bool) async -> PubkyProfile? {
        PubkyProfile(publicKey: publicKey, name: "Alice", bio: "", imageUrl: nil, links: [], status: nil)
    }
}
