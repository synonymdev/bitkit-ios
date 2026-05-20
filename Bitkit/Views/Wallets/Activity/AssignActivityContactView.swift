import SwiftUI

struct AssignActivityContactView: View {
    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var navigation: NavigationViewModel

    let activityId: String
    @State private var selectedContactKey: String?

    private var contacts: [PubkyContact] {
        contactsManager.contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("slashtags__contact_assign"))
                .padding(.horizontal, 16)

            if contacts.isEmpty {
                Spacer()
                BodyMText(t("slashtags__contacts_no_found"), textColor: .white64)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("contacts__nav_title").localizedUppercase, textColor: .white64)
                            .padding(.bottom, 16)

                        CustomDivider()

                        ForEach(contacts) { contact in
                            PubkyContactRow(
                                contact: contact,
                                verticalPadding: 24,
                                isLoading: selectedContactKey == contact.publicKey
                            ) {
                                Task {
                                    await assign(contact)
                                }
                            }
                            .accessibilityIdentifier("AssignContact-\(contact.publicKey)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .bottomSafeAreaPadding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }

    private func assign(_ contact: PubkyContact) async {
        guard selectedContactKey == nil else { return }
        selectedContactKey = contact.publicKey
        defer { selectedContactKey = nil }

        do {
            try await activityList.setContact(contact.publicKey, forPaymentId: activityId)
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to assign contact to activity \(activityId): \(error)", context: "AssignActivityContactView")
            app.toast(type: .error, title: t("contacts__error_saving"), description: error.localizedDescription)
        }
    }
}
