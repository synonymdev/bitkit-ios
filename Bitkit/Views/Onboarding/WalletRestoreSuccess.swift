import SwiftUI

struct WalletRestoreSuccess: View {
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack(spacing: 0) {
            DisplayText(t("onboarding__restore_success_header"), accentColor: .greenAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .padding(.bottom, 14)

            BodyMText(t("onboarding__restore_success_text"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("check")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            CustomButton(title: t("onboarding__get_started")) {
                Haptics.play(.light)
                wallet.isRestoringWallet = false
            }
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
    }
}
