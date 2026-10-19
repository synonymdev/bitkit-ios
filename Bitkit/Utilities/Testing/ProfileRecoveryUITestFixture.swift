#if DEBUG
    import SwiftUI

    struct ProfileRecoveryUITestFixture: View {
        @StateObject private var profile = ProfileRecoveryTestManager()
        @StateObject private var app = AppViewModel()
        @StateObject private var navigation = NavigationViewModel()
        @StateObject private var contacts = ContactsManager()
        @State private var clipboard = ""

        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Button("Restore") { profile.restoreSession() }
                        .accessibilityIdentifier("ProfileFixtureRestore")
                        .accessibilityValue(profile.currentSession == nil ? "Unavailable" : "Restored")
                    Button("Fail") { profile.finish(success: false) }
                        .accessibilityIdentifier("ProfileFixtureFail")
                    Button("Load") { profile.finish(success: true) }
                        .accessibilityIdentifier("ProfileFixtureLoad")
                    Button("Clipboard") { clipboard = UIPasteboard.general.string ?? "" }
                        .accessibilityIdentifier("ProfileFixtureClipboard")
                    Button("Reset copy") {
                        UIPasteboard.general.string = "not-copied"
                        clipboard = "not-copied"
                    }
                    .accessibilityIdentifier("ProfileFixtureResetClipboard")
                }
                CaptionText(clipboard)
                    .accessibilityIdentifier("ProfileFixtureClipboardValue")
                CaptionText(profile.isLoadingProfile ? "Loading" : profile.isDisconnectPending ? "Disconnecting" : "Idle")
                    .accessibilityIdentifier("ProfileFixtureStatus")
                NavigationStack(path: $navigation.path) {
                    ProfileDestinationView(hasSeenIntro: true)
                        .navigationDestination(for: Route.self) { route in
                            if route == .editProfile {
                                CaptionText("Edit profile")
                                    .accessibilityIdentifier("ProfileFixtureEditing")
                            }
                        }
                }
            }
            .environmentObject(profile as PubkyProfileManager)
            .environmentObject(app)
            .environmentObject(navigation)
            .environmentObject(contacts)
            .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private final class ProfileRecoveryTestManager: PubkyProfileManager {
        static let savedProfile = PubkyProfile(
            publicKey: "profile-recovery-fixture", name: "Saved public profile", bio: "Public biography",
            imageUrl: nil, links: [], tags: ["public-tag"], status: nil
        )

        @Published private(set) var isDisconnectPending = false
        private var hasLoaded = false
        private var pendingResult: CheckedContinuation<Bool, Never>?

        override var hasExistingIdentity: Bool {
            true
        }

        override var profileForDisplay: PubkyProfile? {
            profile ?? Self.savedProfile
        }

        override var publicKeyForDisplay: String? {
            Self.savedProfile.publicKey
        }

        override func restoreSessionIfNeeded(
            hasStoredIdentity: () throws -> Bool,
            initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
        ) async {}

        override func loadProfile() async {
            guard hasLoaded else {
                hasLoaded = true
                return
            }
            isLoadingProfile = true
            let success = await withCheckedContinuation { pendingResult = $0 }
            if success { profile = Self.savedProfile }
            isLoadingProfile = false
        }

        override func signOut() async throws {
            isDisconnectPending = true
            _ = await withCheckedContinuation { pendingResult = $0 }
            isDisconnectPending = false
            throw PubkyServiceError.sessionNotActive
        }

        func restoreSession() {
            publicKey = Self.savedProfile.publicKey
            authState = .authenticated
        }

        func finish(success: Bool) {
            let result = pendingResult
            pendingResult = nil
            result?.resume(returning: success)
        }
    }
#endif
