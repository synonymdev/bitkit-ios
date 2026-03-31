import SwiftUI

struct SecurityDisablePin: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var errorIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__pin_disable_button"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(t("security__pin_disable_text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 32)

                Spacer()

                if !errorMessage.isEmpty {
                    BodySText(errorMessage, textColor: .brandAccent)
                        .padding(.bottom, 16)
                        .accessibilityIdentifier(errorIdentifier ?? "WrongPIN")
                        .onTapGesture {
                            sheets.showSheet(.forgotPin)
                        }
                }
            }
            .padding(.horizontal, 32)

            PinInput(pinInput: $pinInput) { pin in
                if pin.count == 4 {
                    onPinEntered(pin)
                } else if pin.count == 1 {
                    errorMessage = ""
                    errorIdentifier = nil
                }
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .sheetBackground()
    }

    private func onPinEntered(_ pin: String) {
        if settings.pinCheck(pin: pin) {
            do {
                try settings.removePin(pin: pin)
                navigation.navigateBack()
                sheets.hideSheet()
            } catch {
                Logger.error("Failed to disable PIN: \(error)", context: "SecurityDisablePin")
                errorMessage = t("security__cp_try_again")
                errorIdentifier = "WrongPIN"
                pinInput = ""
            }
            return
        }

        pinInput = ""

        let pinAttemptOutcome = settings.pinAttemptOutcomeAfterFailure()
        if case .exceededAttempts = pinAttemptOutcome {
            Task {
                await settings.wipeWalletAfterExceededPinAttempts(
                    app: app,
                    wallet: wallet,
                    session: session,
                    sheets: sheets,
                    context: "SecurityDisablePin"
                )
            }
            return
        }

        errorMessage = pinAttemptOutcome.errorMessage ?? ""
        errorIdentifier = pinAttemptOutcome.errorIdentifier

        Haptics.notify(.error)
    }
}
