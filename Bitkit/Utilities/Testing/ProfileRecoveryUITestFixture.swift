#if DEBUG
    import SwiftUI

    struct ProfileRecoveryUITestFixture: View {
        @StateObject private var profile: ProfileRecoveryTestManager
        @StateObject private var local: ProfileRecoveryLocalState
        @StateObject private var app = AppViewModel()
        @StateObject private var navigation = NavigationViewModel()
        @StateObject private var contacts = ContactsManager()
        @State private var clipboard = ""

        init() {
            let local = ProfileRecoveryLocalState()
            _local = StateObject(wrappedValue: local)
            _profile = StateObject(wrappedValue: ProfileRecoveryTestManager(local: local))
        }

        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Button("Restore") { profile.restoreSession() }
                        .accessibilityIdentifier("ProfileFixtureRestore")
                        .accessibilityValue(profile.currentSession == nil ? "Unavailable" : "Restored")
                    Button("Fail") { finish(success: false) }
                        .accessibilityIdentifier("ProfileFixtureFail")
                    Button("Load") { finish(success: true) }
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
                CaptionText(profile.isLoadingProfile ? "Loading" : local.isPending ? "Disconnecting" : "Idle")
                    .accessibilityIdentifier("ProfileFixtureStatus")
                    .accessibilityValue(profile.events.joined(separator: "\n"))
                CaptionText(
                    "Credentials: \(local.credentialsPresent ? "present" : "cleared"), watermark: \(local.watermark), remote: \(local.remoteCalls)"
                )
                .accessibilityIdentifier("ProfileFixtureLocalState")
                CaptionText(profile.pendingProfileRemovalID?.uuidString ?? "None")
                    .accessibilityIdentifier("ProfileFixturePendingID")
                NavigationStack(path: $navigation.path) {
                    Group {
                        if !local.credentialsPresent, profile.removalRecovery == .ready {
                            CaptionText("Local cleanup complete")
                                .accessibilityIdentifier("ProfileFixtureCompleted")
                        } else {
                            ProfileDestinationView(hasSeenIntro: true)
                        }
                    }
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

        private func finish(success: Bool) {
            if local.isPending {
                local.finish(success: success)
            } else {
                profile.finish(success: success)
            }
        }
    }

    @MainActor
    private final class ProfileRecoveryLocalState: ObservableObject {
        @Published private(set) var isPending = false
        @Published private(set) var credentialsPresent = true
        @Published private(set) var watermark = 42
        @Published private(set) var remoteCalls = 0
        private var pendingResult: CheckedContinuation<Bool, Never>?

        func complete() async throws {
            isPending = true
            defer { isPending = false }
            let success = await withCheckedContinuation { pendingResult = $0 }
            guard success else { throw KeychainError.failedToDelete }
            credentialsPresent = false
            watermark = 0
        }

        func finish(success: Bool) {
            let result = pendingResult
            pendingResult = nil
            result?.resume(returning: success)
        }

        func rejectRemote() throws {
            remoteCalls += 1
            throw PubkyServiceError.sessionNotActive
        }
    }

    @MainActor
    private final class ProfileRecoveryTestManager: PubkyProfileManager {
        static let savedProfile = PubkyProfile(
            publicKey: "profile-recovery-fixture", name: "Saved public profile", bio: "Public biography",
            imageUrl: nil, links: [], tags: ["public-tag"], status: nil
        )

        private let local: ProfileRecoveryLocalState
        @Published private(set) var events: [String] = []
        private var nextOperation = 0
        private var pendingOperation: String?
        private var hasLoaded = false
        private var pendingResult: CheckedContinuation<Bool, Never>?

        init(local: ProfileRecoveryLocalState) {
            self.local = local
            let store = ProfileRemovalStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("profile-ui-\(UUID().uuidString)/pending.json"))
            let services = RemovalServices(
                readProfile: { _ in try await local.rejectRemote(); return nil },
                deleteProfile: { _, _ in try await local.rejectRemote() },
                withdrawPrivate: { try local.rejectRemote() },
                withdrawPublic: { try local.rejectRemote() },
                validateContacts: { _, _ in try local.rejectRemote() },
                revokeSession: { try local.rejectRemote() },
                completeLocal: { try await local.complete() },
                pause: { _ in }, resume: { _ in }
            )
            super.init(removalServices: services, removalStore: store, removalAdmission: ProfileOperationAdmission(store: store))
        }

        override var hasExistingIdentity: Bool {
            local.credentialsPresent
        }

        override var profileForDisplay: PubkyProfile? {
            local.credentialsPresent ? profile ?? Self.savedProfile : nil
        }

        override var publicKeyForDisplay: String? {
            local.credentialsPresent ? Self.savedProfile.publicKey : nil
        }

        override func restoreSessionIfNeeded(
            hasStoredIdentity: () throws -> Bool,
            initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
        ) async {}

        override func loadProfile() async {
            let operation = beginOperation("load")
            guard hasLoaded else {
                record("\(operation) skipped initial load")
                hasLoaded = true
                return
            }
            isLoadingProfile = true
            let success = await withCheckedContinuation {
                record("\(operation) installed; previous=\(pendingOperation ?? "none")")
                pendingOperation = operation
                pendingResult = $0
            }
            record("\(operation) resumed success=\(success)")
            if success {
                profile = Self.savedProfile
            }
            isLoadingProfile = false
            record("\(operation) ended")
        }

        func restoreSession() {
            guard removalRecovery == .ready else { return }
            record("restore action")
            publicKey = Self.savedProfile.publicKey
            authState = .authenticated
        }

        func finish(success: Bool) {
            record("finish action success=\(success); pending=\(pendingOperation ?? "none")")
            let result = pendingResult
            pendingResult = nil
            pendingOperation = nil
            result?.resume(returning: success)
            record("finish returned; resumed=\(result != nil)")
        }

        private func beginOperation(_ name: String) -> String {
            nextOperation += 1
            let operation = "\(name)#\(nextOperation)"
            record("\(operation) entered")
            return operation
        }

        private func record(_ event: String) {
            events.append(event)
            if events.count > 40 {
                events.removeFirst()
            }
        }
    }
#endif
