import SwiftUI

struct ForgotPinSheetItem: SheetItem {
    let id: SheetID = .forgotPin
    let size: SheetSize = .large
}

struct ForgotPinSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    let config: ForgotPinSheetItem

    var body: some View {
        Sheet(id: .forgotPin, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: localizedString("security__pin_forgot_title"))

                VStack(spacing: 0) {
                    BodyMText(localizedString("security__pin_forgot_text"))

                    Spacer()

                    Image("restore")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)

                    Spacer()

                    CustomButton(title: localizedString("security__pin_forgot_reset")) {
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
        // TODO: move to wipeApp()
        Task {
            do {
                try await wallet.wipeWallet()
                settings.resetPinSettings()

                // Show toast notification
                await MainActor.run {
                    app.toast(
                        type: .success,
                        title: localizedString("security__wiped_title"),
                        description: localizedString("security__wiped_message"),
                    )
                }
            } catch {
                Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "PinOnLaunchView")
                await MainActor.run {
                    app.toast(error)
                }
            }
        }
    }
}
