import SwiftUI

struct SendPinScreen: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    var message: String = t("security__pin_send")
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
                BodyMText(message)
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
        let result = settings.verifyPin(pin)
        if result == .correct {
            hasResolvedPinCheck = true
            onPinVerified()
            return
        }

        pinInput = ""

        // A lockout raises the wipe gate in place of this screen.
        guard result != .lockedOut else { return }

        errorMessage = result.errorMessage ?? ""
        errorIdentifier = result.errorIdentifier

        Haptics.notify(.error)
    }
}
