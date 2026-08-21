import Foundation
import LDKNode
import SwiftUI

@MainActor
final class QuickPayPaymentCoordinator {
    static let shared = QuickPayPaymentCoordinator()

    struct Presentation {
        var appendRoute: (SendRoute) -> Void
        var replaceQuickPay: (SendRoute) -> Void
        var addPendingPaymentHash: (String) -> Void
        var routingCacheResetAttempted: Bool
    }

    private struct Operation {
        var dispatched = false
        var presentation: Presentation?
    }

    private let store: QuickPaySpendStore
    private let sendBolt11: (String) async throws -> String
    private let listRows: () async -> [QuickPayReconcileRow]?

    private var operations: [String: Operation] = [:]
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
        for hash in operations.keys {
            if var op = operations[hash] {
                op.presentation = nil
                operations[hash] = op
            }
        }
    }

    func pay(
        app: AppViewModel,
        wallet: WalletViewModel,
        settings: SettingsViewModel,
        currency: CurrencyViewModel,
        presentation: Presentation
    ) {
        let generation = UUID()
        self.generation = generation
        Task {
            await run(
                generation: generation,
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

    static func classify(_ error: Error) -> DispatchClass {
        if PrivatePaykitService.isDuplicatePaymentError(error) {
            return .duplicatePayment
        }
        guard let nodeError = error as? NodeError else {
            return .ambiguous
        }
        switch nodeError {
        case .InvalidInvoice, .InvalidAmount, .InvalidPaymentHash, .InvalidPaymentId, .InvalidNetwork:
            return .preDispatchRejection
        case .DuplicatePayment:
            return .duplicatePayment
        default:
            return .ambiguous
        }
    }

    enum DispatchClass {
        case preDispatchRejection
        case duplicatePayment
        case ambiguous
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

        if var existing = operations[invoiceHash] {
            existing.presentation = presentation
            operations[invoiceHash] = existing
            return
        }

        if store.hasOpenRecord(paymentHash: invoiceHash) {
            operations[invoiceHash] = Operation(dispatched: true, presentation: presentation)
            return
        }

        guard generation == self.generation else { return }

        let amountSats = wallet.sendAmountSats ?? 0
        let reserved: QuickPayLedgerRecord?
        do {
            reserved = try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: amountSats,
                thresholdUsd: settings.quickpayAmount,
                multiplier: settings.quickpayDailyLimitMultiplier,
                rates: .live(currency)
            )
        } catch {
            fail(presentation, error: error, bolt11: bolt11)
            return
        }

        guard let reserved else {
            presentation.replaceQuickPay(PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: app))
            return
        }

        guard generation == self.generation else {
            store.releaseBound(paymentHash: invoiceHash)
            return
        }

        operations[invoiceHash] = Operation(dispatched: false, presentation: presentation)

        do {
            let paymentId = try await sendBolt11(bolt11)
            store.markSubmitted(invoicePaymentHash: invoiceHash, paymentId: paymentId)
            if var op = operations[invoiceHash] {
                op.dispatched = true
                operations[invoiceHash] = op
                if paymentId != invoiceHash {
                    operations[paymentId] = op
                }
            }
        } catch {
            await handleDispatchError(error, invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
            return
        }

        _ = reserved

        guard let attached = operations[invoiceHash]?.presentation else { return }

        do {
            let settled = try await wallet.waitForLightningPayment(hash: invoiceHash) { hash in
                attached.addPendingPaymentHash(hash)
                attached.appendRoute(.pending(paymentHash: hash, retryRoute: .quickpay, paymentRequest: bolt11))
            }
            operations[invoiceHash]?.presentation?.appendRoute(.success(paymentId: String(settled.paymentHash)))
            if let amountSats = wallet.sendAmountSats {
                wallet.sendAmountSats = QuickPayLimits.amountWithFeeSats(
                    amountSats: amountSats,
                    feePaidSats: settled.feePaidSats
                )
            }
        } catch is PaymentTimeoutError {
            return
        } catch {
            operations[invoiceHash]?.presentation?.appendRoute(.failure(SendFailureContext(
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
        let attached = operations[invoiceHash]?.presentation
        switch Self.classify(error) {
        case .duplicatePayment, .preDispatchRejection:
            store.releaseBound(paymentHash: invoiceHash)
            operations.removeValue(forKey: invoiceHash)
        case .ambiguous:
            await store.reconcile(rows: listRows(), liveSubmittingHashes: [])
            if store.record(matching: invoiceHash) != nil {
                if var op = operations[invoiceHash] {
                    op.dispatched = true
                    operations[invoiceHash] = op
                }
            } else {
                operations.removeValue(forKey: invoiceHash)
            }
        }

        attached?.appendRoute(.failure(SendFailureContext(
            error: error,
            retryRoute: .quickpay,
            routingCacheResetAttempted: presentation.routingCacheResetAttempted,
            paymentRequest: bolt11
        )))
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
