import SwiftUI

struct ResetAndRestore: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var session: SessionManager

    @State private var showAlert = false

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(localizedString("security__reset_text"))
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
                    title: localizedString("security__reset_button_backup"),
                    variant: .secondary
                ) {
                    sheets.showSheet(.backup, data: BackupConfig(view: .mnemonic))
                }

                CustomButton(title: localizedString("security__reset_button_reset")) {
                    showAlert = true
                }
            }
        }
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .accessibilityIdentifier("ResetAndRestore")
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text(localizedString("security__reset_dialog_title")),
                message: Text(localizedString("security__reset_dialog_desc")),
                primaryButton: .destructive(Text(localizedString("security__reset_confirm"))) {
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
                    title: "Wipe Failed",
                    description: "Bitkit was unable to reset your wallet data. Please try again."
                )
            }
        }
    }
}
