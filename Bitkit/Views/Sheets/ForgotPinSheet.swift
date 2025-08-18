import SwiftUI

struct ForgotPinSheetItem: SheetItem {
    let id: SheetID = .forgotPin
    let size: SheetSize = .large
}

struct ForgotPinSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    let config: ForgotPinSheetItem

    var body: some View {
        Sheet(id: .forgotPin, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("security__pin_forgot_title"))

                VStack(spacing: 0) {
                    BodyMText(t("security__pin_forgot_text"))

                    Spacer()

                    Image("restore")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)

                    Spacer()

                    CustomButton(title: t("security__pin_forgot_reset")) {
                        onReset()
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationBarHidden(true)
            .padding(.horizontal, 16)
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
                Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "ForgotPinSheet")
                app.toast(error)
            }
        }
    }
}
