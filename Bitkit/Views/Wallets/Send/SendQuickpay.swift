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
    var spendStore: QuickPaySpendStore = .shared
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
        var bolt11Invoice: String?

        do {
            // Handle LNURL Pay
            if let lnurlPayData = app.lnurlPayData {
                // Set the amount in sats for the success screen
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

            let parsedInvoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
            let paymentHash = String(describing: parsedInvoice.paymentHash())

            // Quickpay only triggers for invoices with built-in amounts, so pass sats: nil
            // to let LDK use the invoice's native millisatoshi precision.
            do {
                let settled = try await wallet.sendWithTimeout(
                    bolt11: bolt11,
                    sats: nil,
                    onTimeout: {
                        app.addPendingPaymentHash(paymentHash)
                        navigationPath.append(.pending(paymentHash: paymentHash, retryRoute: .quickpay, paymentRequest: bolt11))
                    }
                )
                wallet.sendAmountSats = QuickPayLimits.amountWithFeeSats(
                    amountSats: amountSats,
                    feePaidSats: settled.feePaidSats
                )
                Logger.info("Quickpay payment successful: \(paymentHash)")
                navigationPath.append(.success(paymentId: paymentHash))
            } catch is PaymentTimeoutError {
                spendStore.trackPending(
                    paymentHash: paymentHash,
                    amountSats: reservation.amountSats,
                    dayKey: reservation.dayKey
                )
                return
            } catch {
                reservation.release()
                throw error
            }
        } catch is PaymentTimeoutError {
            // onTimeout callback already navigated to .pending; suppress throw
            return
        } catch {
            handlePaymentError(error, paymentRequest: bolt11Invoice)
        }
    }

    private func reserveDailySpend(amountSats: UInt64) throws -> ReservedQuickPaySpend? {
        let multiplier = QuickPayLimits.sanitizedMultiplier(settings.quickpayDailyLimitMultiplier)
        guard let dailyCapSats = QuickPayLimits.dailyCapSats(
            thresholdUsd: settings.quickpayAmount,
            multiplier: multiplier,
            currency: currency
        ) else {
            throw AppError(
                message: t("wallet__send_quickpay__currency_conversion"),
                debugMessage: "Currency conversion failed"
            )
        }

        let dayKey = QuickPaySpendStore.dayKey()
        let reserved = spendStore.tryReserve(amountSats: amountSats, dayKey: dayKey, dailyCapSats: dailyCapSats)
        guard reserved else {
            Logger.info("Skipping QuickPay pay: daily spend reserve failed for '\(amountSats)'")
            navigationPath.append(PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: app))
            return nil
        }

        return ReservedQuickPaySpend(amountSats: amountSats, dayKey: dayKey, store: spendStore)
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

private struct ReservedQuickPaySpend {
    let amountSats: UInt64
    let dayKey: String
    let store: QuickPaySpendStore

    func release() {
        store.release(amountSats: amountSats, dayKey: dayKey)
    }
}
