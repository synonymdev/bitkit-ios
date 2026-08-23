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

    private final class InFlightOp {
        let invoiceHash: String
        let bolt11: String
        var presentation: Presentation?
        var paymentId: String?
        var dispatched = false
        var emitted = false
        var runActive = false
        var waiterActive = false

        init(invoiceHash: String, bolt11: String, presentation: Presentation?) {
            self.invoiceHash = invoiceHash
            self.bolt11 = bolt11
            self.presentation = presentation
        }
    }

    private enum AmbiguousApply {
        case unchanged
        case succeeded
        case failed
    }

    private let store: QuickPaySpendStore
    private let sendBolt11: (String) async throws -> String
    private let listRows: () async throws -> [QuickPayReconcileRow]?

    private var operations: [String: InFlightOp] = [:]
    private var generation = UUID()
    private var payRequested = false

    var liveSubmittingHashes: Set<String> {
        Set(operations.values.map(\.invoiceHash))
    }

    init(
        store: QuickPaySpendStore = .shared,
        sendBolt11: ((String) async throws -> String)? = nil,
        listRows: (() async throws -> [QuickPayReconcileRow]?)? = nil
    ) {
        self.store = store
        self.sendBolt11 = sendBolt11 ?? { bolt11 in
            try await String(LightningService.shared.send(bolt11: bolt11))
        }
        self.listRows = listRows ?? {
            await LightningService.shared.listPayments()?.map(QuickPayReconcileRow.init)
        }
    }

    func hasOpen(_ paymentHash: String) -> Bool {
        guard !paymentHash.isEmpty else { return false }
        return operations[paymentHash] != nil || store.record(matching: paymentHash) != nil
    }

    func detach() {
        generation = UUID()
        payRequested = false
        for op in uniqueOps {
            op.presentation = nil
        }
    }

    func pay(
        app: AppViewModel,
        wallet: WalletViewModel,
        settings: SettingsViewModel,
        currency: CurrencyViewModel,
        presentation: Presentation
    ) {
        guard !payRequested else { return }
        payRequested = true
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
            let rows = await loadPaymentRows()
            let live = liveSubmittingHashes
            let dispatched = Set(uniqueOps.filter(\.dispatched).map(\.invoiceHash))
            store.reconcile(rows: rows, liveSubmittingHashes: live) { record, match in
                Self.isAttributedFailure(
                    record: record,
                    dispatched: dispatched.contains(record.invoicePaymentHash),
                    paymentId: match.paymentId,
                    paymentHash: match.invoicePaymentHash
                )
            }
        }
    }

    @discardableResult
    func complete(paymentId: String?, paymentHash: String?, success: Bool) -> QuickPayCompletionOutcome {
        let keys = [paymentId, paymentHash].compactMap { $0 }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return .none }
        guard let record = keys.compactMap({ store.record(matching: $0) }).first else {
            handleSettled(paymentId: paymentId, paymentHash: paymentHash)
            return .none
        }
        let op = operations[record.invoicePaymentHash] ?? record.paymentId.flatMap { operations[$0] }
        if !success, !Self.isAttributedFailure(
            record: record,
            dispatched: op?.dispatched == true,
            paymentId: paymentId,
            paymentHash: paymentHash
        ) {
            return .none
        }
        let outcome = store.signalCompletion(paymentId: paymentId, paymentHash: paymentHash, success: success)
        if let op {
            removeOp(op)
        }
        return outcome
    }

    func handleSettled(paymentId: String?, paymentHash: String?) {
        let keys = [paymentId, paymentHash].compactMap { $0 }.filter { !$0.isEmpty }
        for key in keys {
            if let op = operations[key] {
                removeOp(op)
                return
            }
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

    static func isDuplicatePayment(_ error: Error) -> Bool {
        guard let nodeError = error as? NodeError else {
            return false
        }
        if case .DuplicatePayment = nodeError {
            return true
        }
        return false
    }

    private func run(
        generation: UUID,
        app: AppViewModel,
        wallet: WalletViewModel,
        settings: SettingsViewModel,
        currency: CurrencyViewModel,
        presentation: Presentation
    ) async {
        guard generation == self.generation else { return }

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

        if let existing = operations[invoiceHash] {
            existing.presentation = presentation
            if existing.emitted {
                replayPending(existing)
            } else if !existing.runActive {
                emitPending(existing)
            }
            return
        }

        if store.record(matching: invoiceHash) != nil {
            let op = InFlightOp(invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
            op.dispatched = true
            op.runActive = true
            register(op)
            await settleRecovered(op)
            op.runActive = false
            return
        }

        guard generation == self.generation else { return }

        let amountSats = wallet.sendAmountSats ?? 0
        let op = InFlightOp(invoiceHash: invoiceHash, bolt11: bolt11, presentation: presentation)
        op.runActive = true
        register(op)
        defer { op.runActive = false }
        do {
            guard try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: amountSats,
                thresholdUsd: settings.quickpayAmount,
                multiplier: settings.quickpayDailyLimitMultiplier,
                rates: .live(currency),
                keepHashes: liveSubmittingHashes
            ) != nil else {
                if store.record(matching: invoiceHash) != nil {
                    op.dispatched = true
                    await settleRecovered(op)
                    return
                }
                removeOp(op)
                presentation.replaceQuickPay(PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: app))
                return
            }
        } catch {
            removeOp(op)
            fail(presentation, error: error, bolt11: bolt11)
            return
        }

        guard generation == self.generation else {
            store.releaseBound(paymentHash: invoiceHash)
            removeOp(op)
            return
        }

        op.dispatched = true
        do {
            let paymentId = try await sendBolt11(bolt11)
            store.markSubmitted(invoicePaymentHash: invoiceHash, paymentId: paymentId)
            op.paymentId = paymentId
            if !paymentId.isEmpty, paymentId != invoiceHash {
                operations[paymentId] = op
            }
        } catch {
            await handleDispatchError(error, op: op)
            return
        }

        if store.record(matching: invoiceHash) == nil {
            emitSuccess(op)
            return
        }

        let attached = op.presentation ?? presentation
        op.waiterActive = true
        do {
            let settled = try await wallet.waitForLightningPayment(hash: invoiceHash) { _ in
                self.emitPending(op)
            }
            emitSuccess(op, paymentId: String(settled.paymentHash))
            if let amountSats = wallet.sendAmountSats {
                wallet.sendAmountSats = QuickPayLimits.amountWithFeeSats(
                    amountSats: amountSats,
                    feePaidSats: settled.feePaidSats
                )
            }
        } catch is PaymentTimeoutError {
            emitPending(op)
        } catch {
            emitFailure(op, error: error, routingCacheResetAttempted: attached.routingCacheResetAttempted)
        }
        op.waiterActive = false
    }

    private func handleDispatchError(_ error: Error, op: InFlightOp) async {
        let attached = op.presentation
        if Self.isHardReject(error) {
            store.releaseBound(paymentHash: op.invoiceHash)
            emitFailure(op, error: error, routingCacheResetAttempted: attached?.routingCacheResetAttempted ?? false)
            removeOp(op)
            return
        }

        let rows = await loadPaymentRows()
        let applied: AmbiguousApply = if let record = store.record(matching: op.invoiceHash), let rows {
            applyAmbiguousLookup(
                record: record,
                rows: rows,
                duplicate: Self.isDuplicatePayment(error),
                op: op
            )
        } else {
            .unchanged
        }

        if store.record(matching: op.invoiceHash) != nil {
            op.dispatched = true
            emitPending(op)
            return
        }

        switch applied {
        case .succeeded:
            emitSuccess(op)
        case .failed, .unchanged:
            emitFailure(op, error: error, routingCacheResetAttempted: attached?.routingCacheResetAttempted ?? false)
        }
        removeOp(op)
    }

    private func settleRecovered(_ op: InFlightOp) async {
        let rows = await loadPaymentRows()
        guard let record = store.record(matching: op.invoiceHash) else {
            emitPending(op)
            return
        }
        let match = rows.flatMap { QuickPaySpendStore.ledgerMatch(record: record, rows: $0) }
        switch match?.status {
        case .succeeded:
            _ = complete(paymentId: record.paymentId, paymentHash: op.invoiceHash, success: true)
            emitSuccess(op)
        case .failed:
            let outcome = complete(paymentId: record.paymentId, paymentHash: op.invoiceHash, success: false)
            if outcome.wasQuickPay {
                emitFailure(
                    op,
                    error: AppError(
                        message: t("wallet__payment_failed_description"),
                        debugMessage: "Recovered QuickPay payment failed"
                    ),
                    routingCacheResetAttempted: op.presentation?.routingCacheResetAttempted ?? false
                )
            } else {
                emitPending(op)
            }
        default:
            emitPending(op)
        }
    }

    private func applyAmbiguousLookup(
        record: QuickPayLedgerRecord,
        rows: [QuickPayReconcileRow],
        duplicate: Bool,
        op: InFlightOp
    ) -> AmbiguousApply {
        guard let match = QuickPaySpendStore.ledgerMatch(record: record, rows: rows) else {
            return .unchanged
        }
        switch match.status {
        case .pending:
            return .unchanged
        case .succeeded:
            if duplicate, record.paymentId == nil {
                store.releaseBound(paymentHash: record.invoicePaymentHash)
            } else {
                store.dropBound(paymentHash: record.invoicePaymentHash)
            }
            return .succeeded
        case .failed:
            let attributed = Self.isAttributedFailure(
                record: record,
                dispatched: op.dispatched,
                paymentId: match.paymentId,
                paymentHash: match.invoicePaymentHash
            )
            guard attributed else { return .unchanged }
            store.releaseBound(paymentHash: record.invoicePaymentHash)
            return .failed
        }
    }

    private func loadPaymentRows() async -> [QuickPayReconcileRow]? {
        do {
            return try await listRows()
        } catch is CancellationError {
            return nil
        } catch {
            Logger.debug("QuickPay payment lookup failed: \(error)", context: "QuickPayPaymentCoordinator")
            return nil
        }
    }

    private static func isAttributedFailure(
        record: QuickPayLedgerRecord,
        dispatched: Bool,
        paymentId: String?,
        paymentHash: String?
    ) -> Bool {
        if let storedId = record.paymentId, storedId == paymentId || storedId == paymentHash {
            return true
        }
        if dispatched, paymentHash == record.invoicePaymentHash || paymentId == record.invoicePaymentHash {
            return true
        }
        if record.paymentId != nil, paymentHash == record.invoicePaymentHash || paymentId == record.invoicePaymentHash {
            return true
        }
        return false
    }

    private func register(_ op: InFlightOp) {
        operations[op.invoiceHash] = op
        if let paymentId = op.paymentId, !paymentId.isEmpty, paymentId != op.invoiceHash {
            operations[paymentId] = op
        }
    }

    private func removeOp(_ op: InFlightOp) {
        operations = operations.filter { $0.value !== op }
    }

    private var uniqueOps: [InFlightOp] {
        var seen = Set<ObjectIdentifier>()
        return operations.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func emitPending(_ op: InFlightOp) {
        guard let presentation = op.presentation else { return }
        if op.emitted {
            return
        }
        op.emitted = true
        presentation.addPendingPaymentHash(op.invoiceHash)
        presentation.appendRoute(.pending(paymentHash: op.invoiceHash, retryRoute: .quickpay, paymentRequest: op.bolt11))
    }

    private func replayPending(_ op: InFlightOp) {
        op.presentation?.addPendingPaymentHash(op.invoiceHash)
        op.presentation?.appendRoute(.pending(paymentHash: op.invoiceHash, retryRoute: .quickpay, paymentRequest: op.bolt11))
    }

    private func emitSuccess(_ op: InFlightOp, paymentId: String? = nil) {
        if op.emitted {
            return
        }
        op.emitted = true
        op.presentation?.appendRoute(.success(paymentId: paymentId ?? op.invoiceHash))
        removeOp(op)
    }

    private func emitFailure(_ op: InFlightOp, error: Error, routingCacheResetAttempted: Bool) {
        if op.emitted {
            return
        }
        op.emitted = true
        op.presentation?.appendRoute(.failure(SendFailureContext(
            error: error,
            retryRoute: .quickpay,
            routingCacheResetAttempted: routingCacheResetAttempted,
            paymentRequest: op.bolt11
        )))
        removeOp(op)
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
