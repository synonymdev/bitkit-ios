import SwiftUI

struct PayContactsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var wallet: WalletViewModel

    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("profile__pay_contacts_nav_title"))
                .padding(.horizontal, 16)

            Spacer()

            Image("coin-stack")
                .resizable()
                .scaledToFit()
                .frame(width: 279)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(
                    t("profile__pay_contacts_title"),
                    accentColor: .pubkyGreen
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

                BodyMText(t("profile__pay_contacts_description"), textColor: .white64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Spacer()

            CustomButton(title: t("common__continue"), isLoading: isSaving) {
                await continueFlow()
            }
            .accessibilityIdentifier("PayContactsContinue")
            .padding(.top, 16)
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
            let canUsePrivatePayments = pubkyProfile.hasLocalSecretKeyForCurrentProfile
            if canUsePrivatePayments, let publicKey = pubkyProfile.publicKey {
                try await contactsManager.loadContactsIfNeeded(for: publicKey)
            }

            try await ContactPaymentsService.setEnabled(
                true,
                wallet: wallet,
                contactPublicKeys: contactsManager.contacts.map(\.publicKey),
                canUsePrivatePayments: canUsePrivatePayments
            )
            navigation.path = [.profile]
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
