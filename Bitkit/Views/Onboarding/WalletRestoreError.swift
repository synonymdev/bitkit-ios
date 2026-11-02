import SwiftUI

struct WalletRestoreError: View {
    var title = t("onboarding__restore_failed_header")
    var message = t("onboarding__restore_failed_text")
    let onRetry: () async -> Void
    var onExportLogs: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            DisplayText(title, accentColor: .redAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .padding(.bottom, 14)

            BodyMText(message)
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

            if let onExportLogs {
                CustomButton(title: t("lightning__conn_button_export_logs"), variant: .secondary, action: onExportLogs)
                    .padding(.top, 16)
            }
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
    }
}
