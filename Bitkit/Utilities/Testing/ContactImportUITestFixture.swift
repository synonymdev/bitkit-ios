#if DEBUG
    import SwiftUI

    struct ContactImportUITestFixture: View {
        @StateObject private var manager = PendingContactImportManager()
        @StateObject private var app = AppViewModel()
        @StateObject private var navigation = NavigationViewModel()
        @StateObject private var profile = PubkyProfileManager()

        var body: some View {
            VStack(spacing: 8) {
                CaptionText("Imports: \(manager.importCount), saves: \(manager.savedKeys.count)")
                    .accessibilityIdentifier("ContactImportFixtureCounts")
                CaptionText(manager.hasPendingImport ? "Preview retained" : "Preview cleared")
                    .accessibilityIdentifier("ContactImportFixturePreview")
                CustomButton(title: "Finish save", size: .small) {
                    manager.finishSave()
                }
                .disabled(!manager.isSavePending)
                .accessibilityIdentifier("ContactImportFixtureFinishSave")

                NavigationStack(path: $navigation.path) {
                    ContactImportOverviewView(profile: manager.fixtureProfile, contacts: manager.fixtureContacts)
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .contactImportSelect:
                                ContactImportSelectView(contacts: manager.fixtureContacts)
                            case .payContacts:
                                CaptionText(manager.savedKeys.joined(separator: ","))
                                    .accessibilityIdentifier("ContactImportFixtureCompleted")
                            default:
                                EmptyView()
                            }
                        }
                }
            }
            .environmentObject(manager as ContactsManager)
            .environmentObject(app)
            .environmentObject(navigation)
            .environmentObject(profile)
            .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private final class PendingContactImportManager: ContactsManager {
        @Published private(set) var importCount = 0
        @Published private(set) var savedKeys: [String] = []
        @Published private(set) var isSavePending = false
        private var pendingSave: CheckedContinuation<Void, Never>?

        let fixtureProfile = PubkyProfile(publicKey: "pubky-fixture", name: "Fixture", bio: "", imageUrl: nil, links: [], status: nil)
        let fixtureContacts = ["Alice", "Bob"].map { name in
            PubkyContact(publicKey: "pubky-\(name.lowercased())", profile: PubkyProfile(
                publicKey: "pubky-\(name.lowercased())", name: name, bio: "", imageUrl: nil, links: [], status: nil
            ))
        }

        init() {
            super.init()
            pendingImportProfile = fixtureProfile
            pendingImportContacts = fixtureContacts
        }

        override func importContacts(
            contacts selected: [PubkyContact],
            saveContact: (String, String) async throws -> Void
        ) async throws {
            importCount += 1
            try await super.importContacts(contacts: selected) { key, _ in
                if self.savedKeys.isEmpty {
                    await withCheckedContinuation { continuation in
                        self.pendingSave = continuation
                        self.isSavePending = true
                    }
                }
                self.savedKeys.append(key)
            }
        }

        func finishSave() {
            let continuation = pendingSave
            pendingSave = nil
            isSavePending = false
            continuation?.resume()
        }
    }
#endif
