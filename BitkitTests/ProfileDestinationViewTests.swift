@testable import Bitkit
import SwiftUI
import Vision
import XCTest

@MainActor
final class ProfileDestinationViewTests: XCTestCase {
    func testDisconnectedSavedIdentityRendersProfileRetry() async throws {
        snapshotAppDefaultsDomain()
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey]
        let savedValues = try keys.map { try Keychain.load(key: $0) }
        let savedReference = AdoptedPubkyReference.current
        let defaults = UserDefaults.standard
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, savedValues) {
                if let value { try? Keychain.upsert(key: key, data: value) }
                else { try? Keychain.delete(key: key) }
            }
        }

        for source in ["local", "session", "ring", "cached"] {
            for key in keys {
                try Keychain.delete(key: key)
            }
            AdoptedPubkyReference.current = nil
            defaults.removeObject(forKey: "pubky_profile_name")
            switch source {
            case "local": try Keychain.upsert(key: .pubkySecretKey, data: Data("saved-key".utf8))
            case "session": try Keychain.upsert(key: .paykitSession, data: Data("saved-session".utf8))
            case "ring": AdoptedPubkyReference.current = (SharedPubkyKeychain.ringSourceApp, "saved-ring-key")
            default: defaults.set("Saved profile", forKey: "pubky_profile_name")
            }
            let manager = DisconnectedProfileManager()
            manager.isInitialized = true
            manager.sessionRestorationFailed = false
            let window = hostProfile(manager)
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(100))
            let (_, labels) = try snapshot(window, name: "Disconnected profile - \(source)")
            XCTAssertTrue(labels.contains(t("profile__retry_load")), "Missing Retry for \(source): \(labels)")
            XCTAssertTrue(labels.contains(t("profile__sign_out")), "Missing Sign Out for \(source): \(labels)")
            XCTAssertTrue(manager.didAttemptRecovery, "Profile entry should attempt recovery for \(source)")
        }
    }

    func testProfileShowsLoadingUntilRestorationAndProfileFetchFinish() async throws {
        snapshotAppDefaultsDomain()
        let savedReference = AdoptedPubkyReference.current
        AdoptedPubkyReference.current = nil
        defer { AdoptedPubkyReference.current = savedReference }
        UserDefaults.standard.set("Saved profile", forKey: "pubky_profile_name")
        let manager = SuspendedProfileManager()
        manager.isInitialized = true
        defer {
            manager.restoration.finish()
            manager.profileFetch.finish()
        }
        let window = hostProfile(manager)
        defer { close(window) }

        await fulfillment(of: [manager.restoration.started], timeout: 3)
        XCTAssertTrue(manager.isRestoringSession)
        try await assertLoadingScreen(window, name: "Restoring saved session")

        manager.restoration.finish()
        await fulfillment(of: [manager.profileFetch.started], timeout: 3)
        XCTAssertFalse(manager.isRestoringSession)
        XCTAssertTrue(manager.isLoadingProfile)
        try await assertLoadingScreen(window, name: "Fetching profile")

        manager.profileFetch.finish()
        try await assertRetryScreen(window, name: "Recovery failed")

        // Automatic recovery must also update an already visible Retry screen.
        manager.restoration = ProfileOperationGate(name: "Automatic restoration")
        let recovery = Task {
            await (manager as PubkyProfileManager).restoreSessionIfNeeded()
        }
        defer { recovery.cancel() }
        await fulfillment(of: [manager.restoration.started], timeout: 3)
        XCTAssertTrue(manager.isRestoringSession)
        try await assertLoadingScreen(window, name: "Automatic retry in progress")
        manager.restoration.finish()
        await recovery.value
        XCTAssertFalse(manager.isRestoringSession)
        try await assertRetryScreen(window, name: "Automatic retry failed")
    }

    private func hostProfile(_ manager: PubkyProfileManager) -> UIWindow {
        let view = ProfileDestinationView(hasSeenIntro: true)
            .environmentObject(manager)
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .preferredColorScheme(.dark)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func snapshot(_ window: UIWindow, name: String) throws -> (UIImage, [String]) {
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
        return (image, request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
    }

    private func assertLoadingScreen(_ window: UIWindow, name: String) async throws {
        // ActivityIndicator fades in over one second. Inspect its rendered pixels after that animation.
        try await Task.sleep(for: .milliseconds(1200))
        let (image, labels) = try snapshot(window, name: name)
        XCTAssertFalse(labels.contains(t("profile__retry_load")), "Retry visible during \(name): \(labels)")
        XCTAssertFalse(labels.contains(t("profile__sign_out")), "Disconnect visible during \(name): \(labels)")
        let cgImage = try XCTUnwrap(image.cgImage)
        // This center strip excludes navigation and contains the only content in ProfileLoading: its spinner.
        let center = CGRect(
            x: CGFloat(cgImage.width) * 0.4,
            y: CGFloat(cgImage.height) * 0.3,
            width: CGFloat(cgImage.width) * 0.2,
            height: CGFloat(cgImage.height) * 0.4
        )
        let crop = try XCTUnwrap(cgImage.cropping(to: center))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        XCTAssertGreaterThan(pixels.filter { $0 > 64 }.count, 50, "ProfileLoading spinner missing during \(name)")
    }

    private func assertRetryScreen(_ window: UIWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let (_, labels) = try snapshot(window, name: name)
        XCTAssertTrue(labels.contains(t("profile__retry_load")), "Missing Retry after \(name): \(labels)")
        XCTAssertTrue(labels.contains(t("profile__sign_out")), "Missing Disconnect after \(name): \(labels)")
    }
}

@MainActor
private final class DisconnectedProfileManager: PubkyProfileManager {
    var didAttemptRecovery = false

    override func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        didAttemptRecovery = true
    }

    override func loadProfile() async {}
}

private struct ProfileOperationGate {
    let started: XCTestExpectation
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(name: String) {
        started = XCTestExpectation(description: name)
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
private final class SuspendedProfileManager: PubkyProfileManager {
    var restoration = ProfileOperationGate(name: "Session restoration")
    var profileFetch = ProfileOperationGate(name: "Profile fetch")

    override func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        let gate = restoration
        await super.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
            gate.started.fulfill()
            for await _ in gate.stream {}
            throw PubkyServiceError.authFailed("offline")
        }
    }

    override func loadProfile() async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        let gate = profileFetch
        gate.started.fulfill()
        for await _ in gate.stream {}
    }
}
