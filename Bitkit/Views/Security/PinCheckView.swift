import SwiftUI

struct PinCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    let title: String
    let explanation: String
    let onCancel: () -> Void
    let onPinVerified: (String) -> Void

    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var errorIdentifier: String?

    private func handlePinChange(_ pin: String) {
        if pin.count == 4 {
            handlePinComplete(pin)
        } else if pin.count == 1 {
            // Clear error message when user starts typing
            errorMessage = ""
            errorIdentifier = nil
        }
    }

    private func handlePinComplete(_ pin: String) {
        let result = settings.verifyPin(pin)
        if result == .correct {
            Haptics.notify(.success)
            dismiss()
            onPinVerified(pin)
            return
        }

        pinInput = ""
        Haptics.notify(.error)

        // A lockout raises the wipe gate in place of this screen.
        guard result != .lockedOut else { return }

        errorMessage = result.errorMessage ?? ""
        errorIdentifier = result.errorIdentifier
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: title, showMenuButton: false)
                .padding(.bottom, 16)

            BodyMText(explanation, textColor: .textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 40)

            if !errorMessage.isEmpty {
                CaptionText(errorMessage, textColor: .brandAccent)
                    .padding(.bottom, 16)
                    .accessibilityIdentifier(errorIdentifier ?? "WrongPIN")
                    .onTapGesture {
                        sheets.showSheet(.forgotPin)
                    }
            }

            // PIN input component
            PinInput(pinInput: $pinInput, verticalSpace: true) { pin in
                handlePinChange(pin)
            }

            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    onCancel()
                    dismiss()
                }) {
                    Image(systemName: "arrow.left")
                        .foregroundColor(.white)
                        .font(.system(size: 18, weight: .medium))
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PinCheckView(
            title: "Enter PIN",
            explanation: "Please enter your PIN to confirm this payment",
            onCancel: {
                print("Cancelled")
            },
            onPinVerified: { _ in
                print("PIN verified!")
            }
        )
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(SheetViewModel())
    }
    .preferredColorScheme(.dark)
}
