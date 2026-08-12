import LDKNode
import SwiftUI

func sendFailureMessage(for error: Error) -> String {
    let fallbackMessage = t("wallet__payment_failed_description")

    if let reason = (error as? AppError)?.paymentFailureReason {
        return PaymentFailureReason.userMessage(for: reason)
    }

    if let requestError = error as? PaykitPaymentRequestError {
        return requestError.localizedDescription
    }

    return fallbackMessage
}

func shouldResetRoutingCachesOnRetry(for error: Error) -> Bool {
    guard let reason = (error as? AppError)?.paymentFailureReason else {
        return false
    }

    return reason.shouldResetRoutingCachesOnRetry
}

func sendFailureType(for error: Error) -> String {
    if let reason = (error as? AppError)?.paymentFailureReason {
        return compactFailureType(String(describing: reason))
    }

    if let requestError = error as? PaykitPaymentRequestError {
        return compactFailureType(String(describing: requestError))
    }

    if let appError = error as? AppError, let underlyingError = appError.underlyingError {
        return compactFailureType(String(describing: underlyingError))
    }

    return compactFailureType(String(describing: error))
}

private func compactFailureType(_ value: String) -> String {
    var result = value

    if result.hasPrefix("Optional("), result.hasSuffix(")") {
        result = String(result.dropFirst("Optional(".count).dropLast())
    }

    if let parenthesisIndex = result.firstIndex(of: "(") {
        result = String(result[..<parenthesisIndex])
    }

    if let lastComponent = result.split(separator: ".").last {
        result = String(lastComponent)
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct SendFailure: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let context: SendFailureContext
    let onRetryReady: (Bool) -> Void

    private var title: String {
        switch context.retryRoute {
        case .confirm:
            return app.selectedWalletToPayFrom == .lightning ? t("wallet__send_instant_failed") : t("wallet__send_error_tx_failed")
        case .quickpay, .lnurlPayConfirm:
            return t("wallet__send_instant_failed")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: title, showBackButton: false)
                        .accessibilityIdentifier("SendFailure")

                    BodyMText(context.message ?? t("wallet__payment_failed_description"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("SendFailureMessage")

                    Spacer()

                    Image("cross")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer()

                    VStack(spacing: 16) {
                        CustomButton(
                            title: t("wallet__send_error_support"),
                            variant: .secondary,
                            isDisabled: wallet.isRetryingLightningPayment
                        ) {
                            contactSupport()
                        }
                        .accessibilityIdentifier("Support")

                        CustomButton(
                            title: t("common__try_again"),
                            isLoading: wallet.isRetryingLightningPayment
                        ) {
                            retryPayment()
                        }
                        .accessibilityIdentifier("Retry")
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationBarHidden(true)
            .allowSwipeBack(false)
            .sheetBackground()
        }
    }

    private func retryPayment() {
        guard context.resetRoutingCachesOnRetry else {
            onRetryReady(false)
            return
        }

        guard !wallet.isRetryingLightningPayment else { return }
        wallet.isRetryingLightningPayment = true

        Task { @MainActor in
            defer {
                wallet.isRetryingLightningPayment = false
            }

            do {
                var cacheResetError: Error?
                do {
                    try await wallet.resetPaymentRoutingCaches()
                } catch {
                    cacheResetError = error
                }

                try await wallet.start()
                let refreshStartedAt = Date()

                if let cacheResetError {
                    throw cacheResetError
                }

                try await wallet.waitForPaymentRoutingDataRefresh(startedAt: refreshStartedAt)
                onRetryReady(true)
            } catch {
                Logger.error("Failed to reset routing caches before payment retry: \(error)", context: "SendFailure")
                app.toast(error)
            }
        }
    }

    private func contactSupport() {
        sheets.hideSheet()
        navigation.navigate(.reportIssue(ReportIssuePrefill(message: supportMessage())))
    }

    private func supportMessage() -> String {
        return """
        I need help with a failed send payment.

        Failure type: \(context.failureType)
        Payment method: \(app.selectedWalletToPayFrom)
        Routing cache reset attempted: \(context.routingCacheResetAttempted ? "Yes" : "No")

        Payment request: \(context.paymentRequest ?? supportPaymentRequest())

        Please investigate this payment failure.
        """
    }

    private func supportPaymentRequest() -> String {
        if let invoice = app.scannedLightningInvoice {
            return invoice.bolt11
        }

        if let lnurlPayData = app.lnurlPayData {
            return "LNURL: \(lnurlPayData.uri)"
        }

        return "Unavailable"
    }
}
