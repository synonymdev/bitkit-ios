import SwiftUI

struct PayContactsView: View {
    @AppStorage("hasConfirmedPublicPaykitEndpoints") private var hasConfirmedPublicPaykitEndpoints = false
    @AppStorage("sharesPublicPaykitEndpoints") private var sharesPublicPaykitEndpoints = false

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var enablePayments = true
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

            Toggle(isOn: $enablePayments) {
                BodyMText(t("profile__pay_contacts_toggle"), textColor: .white)
            }
            .tint(.pubkyGreen)
            .accessibilityIdentifier("PayContactsToggle")
            .padding(.horizontal, 32)

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
        .onAppear {
            enablePayments = hasConfirmedPublicPaykitEndpoints ? sharesPublicPaykitEndpoints : true
        }
    }

    private func continueFlow() async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: enablePayments)
            sharesPublicPaykitEndpoints = enablePayments
            hasConfirmedPublicPaykitEndpoints = true
            navigation.path = [.profile]
        } catch {
            Logger.error("Failed to sync public payment endpoints: \(error)", context: "PayContactsView")
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
            .environmentObject(NavigationViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
