import Foundation
import LDKNode

@MainActor
final class QuickPayPaymentCoordinator {
    static let shared = QuickPayPaymentCoordinator()

    struct Presentation {
        var appendRoute: (SendRoute) -> Void
        var replaceQuickPay: (SendRoute) -> Void
        var addPendingPaymentHash: (String) -> Void
        var routingCacheResetAttempted: Bool
    }

    private let store: QuickPaySpendStore
    private let sendBolt11: (String) async throws -> String
    private let listRows: () async -> [QuickPayReconcileRow]?

    private var operations: [String: Presentation?] = [:]
    private var generation = UUID()

    var liveSubmittingHashes: Set<String> {
        Set(operations.keys)
    }

    init(
        store: QuickPaySpendStore = .shared,
        sendBolt11: ((String) async throws -> String)? = nil,
        listRows: (() async -> [QuickPayReconcileRow]?)? = nil
    ) {
        self.store = store
        self.sendBolt11 = sendBolt11 ?? { bolt11 in
            try await String(LightningService.shared.send(bolt11: bolt11))
        }
        self.listRows = listRows ?? {
            await LightningService.shared.listPayments()?.map(QuickPayReconcileRow.init)
        }
    }

    func detach() {
        generation = UUID()
        for hash in Array(operations.keys) {
            operations[hash] = Optional.none
        }
    }

    func pay(
        app: AppViewModel,
        wallet: WalletViewModel,
        settings: SettingsViewModel,
        currency: CurrencyViewModel,
        presentation: Presentation
    ) {
        let capturedGeneration = generation
        Task {
            await run(
                generation: capturedGeneration,
                app: app,
                wallet: wallet,
                settings: settings,
                currency: currency,
                presentation: presentation
            )
        }
    }

    func reconcileAgainstLdk() {
        Task {
            let rows = await listRows()
            store.reconcile(rows: rows, liveSubmittingHashes: liveSubmittingHashes)
        }
    }

    func handleSettled(paymentId: String?, paymentHash: String?) {
        for key in [paymentId, paymentHash].compactMap({ $0 }) {
            operations.removeValue(forKey: key)
        }
    }

    static func isHardReject(_ error: Error) -> Bool {
        guard let nodeError = error as? NodeError else {
            return false
        }
        switch nodeError {
        case .InvalidInvoice, .InvalidAmount, .InvalidPaymentHash, .InvalidPaymentId, .InvalidNetwork:
            return true
        default:
            return false
        }
    }

    private func run(
        generation: UUID,
        app: AppViewModel,
        wallet: WalletViewModel,
        settings: SettingsViewModel,
        currency: CurrencyViewModel,
        presentation: Presentation
    ) async {
        var bolt11: String?
        do {
            if let lnurlPayData = app.lnurlPayData {
                wallet.sendAmountSats = lnurlPayData.minSendableSat
                bolt11 = try await LnurlHelper.fetchLnurlInvoice(
                    data: lnurlPayData,
                    amountMsats: lnurlPayData.callbackAmountMsats()
                )
            } else if let scannedInvoice = app.scannedLightningInvoice {
                wallet.sendAmountSats = scannedInvoice.amountSatoshis
                bolt11 = scannedInvoice.bolt11
            }
        } catch {
            guard generation == self.generation else { return }
            fail(presentation, error: error, bolt11: nil)
            return
        }

        guard generation == self.generation else { return }
        guard let bolt11 else {
            fail(presentation, error: AppError(message: t("common__error_body"), debugMessage: "No Lightning invoice found"), bolt11: nil)
            return
        }

        let invoiceHash: String
        do {
            invoiceHash = try String(Bolt11Invoice.fromStr(invoiceStr: bolt11).paymentHash())
        } catch {
            fail(presentation, error: error, bolt11: bolt11)
            return
        }

        if livePresentation(for: invoiceHash) != nil {
            operations[invoiceHash] = presentation
            return
        }

        if store.record(matching: invoiceHash) != nil {
            operations[invoiceHash] = presentation
            await settleRecovered(invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
            return
        }

        guard generation == self.generation else { return }

        let amountSats = wallet.sendAmountSats ?? 0
        operations[invoiceHash] = presentation
        do {
            guard try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: amountSats,
                thresholdUsd: settings.quickpayAmount,
                multiplier: settings.quickpayDailyLimitMultiplier,
                rates: .live(currency)
            ) != nil else {
                if store.record(matching: invoiceHash) != nil {
                    await settleRecovered(invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
                    return
                }
                operations.removeValue(forKey: invoiceHash)
                presentation.replaceQuickPay(PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: app))
                return
            }
        } catch {
            operations.removeValue(forKey: invoiceHash)
            fail(presentation, error: error, bolt11: bolt11)
            return
        }

        guard generation == self.generation else {
            store.releaseBound(paymentHash: invoiceHash)
            operations.removeValue(forKey: invoiceHash)
            return
        }

        do {
            let paymentId = try await sendBolt11(bolt11)
            store.markSubmitted(invoicePaymentHash: invoiceHash, paymentId: paymentId)
            if operations[invoiceHash] != nil, paymentId != invoiceHash {
                operations[paymentId] = operations[invoiceHash]
            }
        } catch {
            await handleDispatchError(error, invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
            return
        }

        if store.record(matching: invoiceHash) == nil {
            presentation.appendRoute(.success(paymentId: invoiceHash))
            return
        }

        let attached = livePresentation(for: invoiceHash) ?? presentation

        do {
            let settled = try await wallet.waitForLightningPayment(hash: invoiceHash) { hash in
                attached.addPendingPaymentHash(hash)
                attached.appendRoute(.pending(paymentHash: hash, retryRoute: .quickpay, paymentRequest: bolt11))
            }
            operations[invoiceHash]??.appendRoute(.success(paymentId: String(settled.paymentHash)))
            if let amountSats = wallet.sendAmountSats {
                wallet.sendAmountSats = QuickPayLimits.amountWithFeeSats(
                    amountSats: amountSats,
                    feePaidSats: settled.feePaidSats
                )
            }
        } catch is PaymentTimeoutError {
            return
        } catch {
            operations[invoiceHash]??.appendRoute(.failure(SendFailureContext(
                error: error,
                retryRoute: .quickpay,
                routingCacheResetAttempted: attached.routingCacheResetAttempted,
                paymentRequest: bolt11
            )))
        }
    }

    private func handleDispatchError(
        _ error: Error,
        invoiceHash: String,
        bolt11: String,
        presentation: Presentation
    ) async {
        let attached = livePresentation(for: invoiceHash) ?? presentation
        if Self.isHardReject(error) {
            store.releaseBound(paymentHash: invoiceHash)
            operations.removeValue(forKey: invoiceHash)
            attached.appendRoute(.failure(SendFailureContext(
                error: error,
                retryRoute: .quickpay,
                routingCacheResetAttempted: attached.routingCacheResetAttempted,
                paymentRequest: bolt11
            )))
            return
        }

        let rows = await listRows()
        store.reconcile(rows: rows, liveSubmittingHashes: [])
        if store.record(matching: invoiceHash) != nil {
            resumePending(invoiceHash: invoiceHash, bolt11: bolt11, presentation: attached)
            return
        }

        operations.removeValue(forKey: invoiceHash)
        if ldkSucceeded(invoiceHash: invoiceHash, rows: rows) {
            attached.appendRoute(.success(paymentId: invoiceHash))
            return
        }
        attached.appendRoute(.failure(SendFailureContext(
            error: error,
            retryRoute: .quickpay,
            routingCacheResetAttempted: attached.routingCacheResetAttempted,
            paymentRequest: bolt11
        )))
    }

    private func settleRecovered(invoiceHash: String, bolt11: String, presentation: Presentation) async {
        let rows = await listRows()
        store.reconcile(rows: rows, liveSubmittingHashes: [])
        if store.record(matching: invoiceHash) != nil {
            resumePending(invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
            return
        }

        operations.removeValue(forKey: invoiceHash)
        if ldkSucceeded(invoiceHash: invoiceHash, rows: rows) {
            presentation.appendRoute(.success(paymentId: invoiceHash))
            return
        }
        fail(
            presentation,
            error: AppError(message: t("wallet__payment_failed_description"), debugMessage: "Recovered QuickPay payment is not pending or succeeded"),
            bolt11: bolt11
        )
    }

    private func ldkSucceeded(invoiceHash: String, rows: [QuickPayReconcileRow]?) -> Bool {
        guard let rows else { return false }
        return rows.contains {
            $0.isOutboundBolt11 && $0.status == .succeeded && (
                $0.invoicePaymentHash == invoiceHash || $0.paymentId == invoiceHash
            )
        }
    }

    private func livePresentation(for invoiceHash: String) -> Presentation? {
        operations[invoiceHash] ?? nil
    }

    private func resumePending(invoiceHash: String, bolt11: String, presentation: Presentation) {
        presentation.addPendingPaymentHash(invoiceHash)
        presentation.appendRoute(.pending(paymentHash: invoiceHash, retryRoute: .quickpay, paymentRequest: bolt11))
    }

    private func fail(_ presentation: Presentation, error: Error, bolt11: String?) {
        presentation.appendRoute(.failure(SendFailureContext(
            error: error,
            retryRoute: .quickpay,
            routingCacheResetAttempted: presentation.routingCacheResetAttempted,
            paymentRequest: bolt11
        )))
    }
}
