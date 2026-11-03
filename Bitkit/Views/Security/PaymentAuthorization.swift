import SwiftUI

/// Asks for the same PIN or biometric check as a payment when the user requires one for payments.
@MainActor
@Observable
final class PaymentAuthorization {
    /// What the PIN confirms, since a check that sends nothing must not say it sends a payment.
    let pinMessage: String
    fileprivate(set) var isAskingForPin = false
    fileprivate(set) var biometricErrorMessage: String?
    @ObservationIgnored private var pinContinuation: CheckedContinuation<Bool, Never>?

    init(pinMessage: String = t("security__pin_send")) {
        self.pinMessage = pinMessage
    }

    func authorize(settings: SettingsViewModel) async -> Bool {
        guard settings.requirePinForPayments && settings.pinEnabled else { return true }
        if settings.useBiometrics && BiometricAuth.isAvailable {
            switch await BiometricAuth.authenticate() {
            case .success:
                return true
            case .cancelled:
                return false
            case let .failed(message):
                biometricErrorMessage = message
                return false
            }
        }
        resolvePin(false)
        isAskingForPin = true
        return await withCheckedContinuation { pinContinuation = $0 }
    }

    fileprivate func resolvePin(_ approved: Bool) {
        isAskingForPin = false
        let continuation = pinContinuation
        pinContinuation = nil
        continuation?.resume(returning: approved)
    }

    fileprivate func dismissBiometricError() {
        biometricErrorMessage = nil
    }
}

private struct PaymentAuthorizationModifier: ViewModifier {
    let authorization: PaymentAuthorization

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { authorization.isAskingForPin },
                set: {
                    if !$0 {
                        authorization.resolvePin(false)
                    }
                }
            )) {
                SendPinScreen(
                    message: authorization.pinMessage,
                    onCancel: { authorization.resolvePin(false) },
                    onPinVerified: { authorization.resolvePin(true) }
                )
            }
            .alert(
                t("security__bio_error_title"),
                isPresented: Binding(
                    get: { authorization.biometricErrorMessage != nil },
                    set: {
                        if !$0 {
                            authorization.dismissBiometricError()
                        }
                    }
                )
            ) {
                Button(t("common__ok")) {}
            } message: {
                Text(authorization.biometricErrorMessage ?? "")
            }
            .onDisappear { authorization.resolvePin(false) }
    }
}

extension View {
    func paymentAuthorization(_ authorization: PaymentAuthorization) -> some View {
        modifier(PaymentAuthorizationModifier(authorization: authorization))
    }
}
