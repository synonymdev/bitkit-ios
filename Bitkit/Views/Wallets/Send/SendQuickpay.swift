import LDKNode
import SwiftUI

struct SendQuickpay: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]
    let routingCacheResetAttempted: Bool
    var replaceQuickPay: (SendRoute) -> Void
    @State private var didStartPayment = false

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__send_quickpay__nav_title"))

            if let lnurlPayData = app.lnurlPayData {
                MoneyStack(sats: Int(lnurlPayData.minSendableSat), showSymbol: true)
            } else if let invoice = app.scannedLightningInvoice {
                MoneyStack(sats: Int(invoice.amountSatoshis), showSymbol: true)
            }

            Spacer(minLength: 32)

            EllipseLoader(variant: .quickpay)
                .padding(.horizontal, 16)

            Spacer(minLength: 32)

            DisplayText(t("wallet__send_quickpay__title"), accentColor: .purpleAccent)
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !didStartPayment else { return }
            didStartPayment = true
            Task {
                await performPayment()
            }
        }
    }

    private func performPayment() async {
        guard app.beginQuickPay() else { return }

        var bolt11Invoice: String?

        do {
            if let lnurlPayData = app.lnurlPayData {
                wallet.sendAmountSats = lnurlPayData.minSendableSat

                bolt11Invoice = try await LnurlHelper.fetchLnurlInvoice(
                    data: lnurlPayData,
                    amountMsats: lnurlPayData.callbackAmountMsats()
                )
            } else if let scannedInvoice = app.scannedLightningInvoice {
                wallet.sendAmountSats = scannedInvoice.amountSatoshis
                bolt11Invoice = scannedInvoice.bolt11
            }

            guard let bolt11 = bolt11Invoice else {
                throw AppError(message: t("common__error_body"), debugMessage: "No Lightning invoice found")
            }

            let amountSats = wallet.sendAmountSats ?? 0
            guard let reservation = try reserveDailySpend(amountSats: amountSats) else {
                return
            }

            var submittedHash = ""
            do {
                let settled = try await wallet.sendWithTimeout(
                    bolt11: bolt11,
                    sats: nil,
                    afterListening: { paymentHash in
                        submittedHash = paymentHash
                        QuickPaySpendStore.shared.remember(paymentHash: paymentHash, reservation: reservation)
                    },
                    onTimeout: { paymentHash in
                        app.addPendingPaymentHash(paymentHash)
                        navigationPath.append(.pending(paymentHash: paymentHash, retryRoute: .quickpay, paymentRequest: bolt11))
                    }
                )
                let paymentHash = String(settled.paymentHash)
                QuickPaySpendStore.shared.clear(paymentHash: paymentHash)
                wallet.sendAmountSats = QuickPayLimits.amountWithFeeSats(
                    amountSats: amountSats,
                    feePaidSats: settled.feePaidSats
                )
                Logger.info("Quickpay payment successful: \(paymentHash)")
                navigationPath.append(.success(paymentId: paymentHash))
            } catch is PaymentTimeoutError {
                return
            } catch {
                if submittedHash.isEmpty {
                    QuickPaySpendStore.shared.releaseUnbound(reservation)
                } else {
                    QuickPaySpendStore.shared.release(paymentHash: submittedHash)
                }
                throw error
            }
        } catch is PaymentTimeoutError {
            return
        } catch {
            handlePaymentError(error, paymentRequest: bolt11Invoice)
        }
    }

    private func reserveDailySpend(amountSats: UInt64) throws -> QuickPaySpendReservation? {
        let reserved = try QuickPaySpendStore.shared.tryReserve(
            amountSats: amountSats,
            thresholdUsd: settings.quickpayAmount,
            multiplier: settings.quickpayDailyLimitMultiplier,
            rates: .live(currency)
        )

        guard let reserved else {
            Logger.info("Skipping QuickPay pay: daily spend reserve failed for '\(amountSats)'")
            replaceQuickPay(PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: app))
            return nil
        }

        return reserved
    }

    private func handlePaymentError(_ error: Error, paymentRequest: String?) {
        Logger.error("Quickpay payment failed: \(error)")

        navigationPath.append(.failure(SendFailureContext(
            error: error,
            retryRoute: .quickpay,
            routingCacheResetAttempted: routingCacheResetAttempted,
            paymentRequest: paymentRequest
        )))
    }
}
