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
            let view = ProfileDestinationView(hasSeenIntro: true)
                .environmentObject(manager as PubkyProfileManager)
                .environmentObject(AppViewModel())
                .environmentObject(NavigationViewModel())
                .environmentObject(ContactsManager())
                .preferredColorScheme(.dark)
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Disconnected profile - \(source)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let labels = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            XCTAssertTrue(labels.contains(t("profile__retry_load")), "Missing Retry for \(source): \(labels)")
            XCTAssertTrue(labels.contains(t("profile__sign_out")), "Missing Sign Out for \(source): \(labels)")
            XCTAssertTrue(manager.didAttemptRecovery, "Profile entry should attempt recovery for \(source)")
        }
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
