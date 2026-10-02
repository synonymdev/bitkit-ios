import SwiftUI

struct PayContactsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var wallet: WalletViewModel

    @State private var isSaving = false

    /// Continue's enable runs in its own task, so it can finish after the user left Pay Contacts or after a Pubky sign-out
    /// stopped it. Like an import that finishes after the user left it, it opens Profile only for an applied enable while
    /// Pay Contacts is still showing.
    static func destinationAfterEnable(isApplied: Bool, currentRoute: Route?) -> Route? {
        isApplied && currentRoute == .payContacts ? .profile : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("profile__pay_contacts_nav_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                VStack {
                    Spacer()

                    Image("coin-stack")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 279)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 8) {
                    DisplayText(
                        t("profile__pay_contacts_title"),
                        accentColor: .pubkyGreen
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                    BodyMText(t("profile__pay_contacts_description"), textColor: .white64)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 16)

            CustomButton(title: t("common__continue"), isLoading: isSaving) {
                await continueFlow()
            }
            .accessibilityIdentifier("PayContactsContinue")
            .padding(.top, 32)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }

    private func continueFlow() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let isApplied = try await ContactPaymentsService.setEnabled(
                true,
                pubkyProfile: pubkyProfile,
                contactsManager: contactsManager,
                operations: .live(wallet: wallet)
            )
            if let destination = Self.destinationAfterEnable(isApplied: isApplied, currentRoute: navigation.currentRoute) {
                navigation.path = [destination]
            }
        } catch {
            Logger.error("Failed to enable contact payments: \(error)", context: "PayContactsView")
            app.toast(
                type: .error,
                title: t("common__error"),
                description: error.localizedDescription
            )
        }
    }
}

#Preview {
    NavigationStack {
        PayContactsView()
            .environmentObject(AppViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
