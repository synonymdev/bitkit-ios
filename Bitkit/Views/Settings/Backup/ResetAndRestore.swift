import SwiftUI

struct ResetAndRestore: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var session: SessionManager

    @State private var showAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__backup__title"))

            VStack(spacing: 0) {
                BodyMText(t("security__reset_text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 32)

                Spacer()

                Image("restore")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer()

                HStack(spacing: 16) {
                    CustomButton(
                        title: t("security__reset_button_backup"),
                        variant: .secondary
                    ) {
                        sheets.showSheet(.backup, data: BackupConfig(view: .mnemonic))
                    }

                    CustomButton(title: t("security__reset_button_reset")) {
                        showAlert = true
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(t("security__reset_dialog_title")),
                message: Text(t("security__reset_dialog_desc")),
                primaryButton: .destructive(Text(t("security__reset_confirm"))) {
                    onReset()
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func onReset() {
        Task {
            do {
                try await AppReset.wipe(
                    app: app,
                    wallet: wallet,
                    session: session
                )

                sheets.hideSheet()
            } catch {
                app.toast(
                    type: .error,
                    title: t("security__wipe_failed_title"),
                    description: t("security__wipe_failed_description")
                )
            }
        }
    }
}
