import SwiftUI

struct WalletRestoreError: View {
    @EnvironmentObject var wallet: WalletViewModel

    @State private var showDialog = false

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

            // TODO: implement retry logic and continue without backup

            CustomButton(title: t("common__try_again")) {
                Haptics.play(.light)
                Task {
                    do {
                        wallet.nodeLifecycleState = .initializing
                        try await wallet.start()
                        try wallet.setWalletExistsState()
                    } catch {
                        Logger.error("Failed to start wallet on retry")
                        Haptics.notify(.error)
                    }
                }
            }

            CustomButton(title: t("onboarding__restore_no_backup_button"), variant: .secondary, size: .large) {
                Haptics.play(.light)
                showDialog = true
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
        .alert(
            t("common__are_you_sure"),
            isPresented: $showDialog,
            actions: {
                Button(t("common__dialog_cancel"), role: .cancel) {
                    showDialog = false
                }

                Button(t("common__yes_proceed"), role: .destructive) {
                    Haptics.play(.light)
                    showDialog = false
                }
            },
            message: {
                Text(t("onboarding__restore_no_backup_warn"))
            }
        )
    }
}
