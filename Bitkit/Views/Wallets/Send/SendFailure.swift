import SwiftUI

func sendFailureMessage(for error: Error) -> String {
    let fallbackMessage = t("wallet__payment_failed_description")
    if let appError = error as? AppError, appError.isGeneric {
        return fallbackMessage
    }

    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? fallbackMessage : message
}

struct SendFailure: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let message: String?
    let retryRoute: SendRetryRoute
    let onRetryReady: () -> Void

    private var title: String {
        switch retryRoute {
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

                    BodyMText(message ?? t("wallet__payment_failed_description"))
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

                    HStack(spacing: 16) {
                        CustomButton(title: t("common__close"), variant: .secondary, isDisabled: wallet.isRetryingLightningPayment) {
                            sheets.hideSheet()
                        }
                        .accessibilityIdentifier("Close")

                        CustomButton(title: t("common__retry"), isLoading: wallet.isRetryingLightningPayment) {
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
                onRetryReady()
            } catch {
                Logger.error("Failed to reset routing caches before payment retry: \(error)", context: "SendFailure")
                app.toast(error)
            }
        }
    }
}
