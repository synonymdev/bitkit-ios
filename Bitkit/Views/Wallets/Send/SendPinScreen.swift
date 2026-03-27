import SwiftUI

struct SendPinScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    let onCancel: () -> Void
    let onPinVerified: () -> Void

    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var errorIdentifier: String?
    @State private var hasResolvedPinCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("security__pin_send_title"), showBackButton: true)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(t("security__pin_send"))
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
        .onDisappear {
            if !hasResolvedPinCheck {
                hasResolvedPinCheck = true
                onCancel()
            }
        }
    }

    private func onPinEntered(_ pin: String) {
        if settings.pinCheck(pin: pin) {
            hasResolvedPinCheck = true
            onPinVerified()
            return
        }

        pinInput = ""

        if settings.hasExceededPinAttempts() {
            handleWalletWipe()
            return
        }

        let remainingAttempts = settings.getRemainingPinAttempts()
        if remainingAttempts == 1 {
            errorMessage = t("security__pin_last_attempt")
            errorIdentifier = "LastAttempt"
        } else {
            errorMessage = t("security__pin_attempts", variables: ["attemptsRemaining": "\(remainingAttempts)"])
            errorIdentifier = "AttemptsRemaining"
        }

        Haptics.notify(.error)
    }

    private func handleWalletWipe() {
        Task {
            do {
                try await AppReset.wipe(
                    app: app,
                    wallet: wallet,
                    session: session,
                    toastType: .warning
                )
                sheets.hideSheet()
            } catch {
                Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "SendPinScreen")
                app.toast(error)
            }
        }
    }
}
