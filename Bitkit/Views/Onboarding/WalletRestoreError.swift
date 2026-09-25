import SwiftUI

struct WalletRestoreError: View {
    let onRetry: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            DisplayText(t("onboarding__restore_failed_header"), accentColor: .redAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .padding(.bottom, 14)

            BodyMText(t("onboarding__restore_failed_text"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("cross")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            CustomButton(title: t("common__try_again")) {
                Haptics.play(.light)
                Task {
                    await onRetry()
                }
            }
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
    }
}
