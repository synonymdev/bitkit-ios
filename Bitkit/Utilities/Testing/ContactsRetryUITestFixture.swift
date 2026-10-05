#if DEBUG
    import Paykit
    import SwiftUI

    struct ContactsRetryUITestFixture: View {
        @StateObject private var app = AppViewModel()
        @StateObject private var navigation = NavigationViewModel()
        @StateObject private var profile = PubkyProfileManager()
        @StateObject private var manager: ContactsManager

        init() {
            let source = RecoveringContactRecords()
            _manager = StateObject(wrappedValue: ContactsManager(
                contactRecords: { try await source.load() },
                fetchRemoteProfile: { _, _ in nil }
            ))
        }

        var body: some View {
            ContactsListView()
                .environmentObject(app)
                .environmentObject(navigation)
                .environmentObject(profile)
                .environmentObject(manager)
                .preferredColorScheme(.dark)
                .onAppear {
                    profile.publicKey = "pubky" + String(repeating: "z", count: 52)
                }
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
#endif
