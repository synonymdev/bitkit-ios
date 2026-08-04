import Foundation
import Paykit

struct PaykitPaymentRequest: Identifiable, Equatable {
    struct ID: Hashable {
        let paymentRequestId: String
        let counterparty: String
        let counterpartyReceiverPath: String
    }

    let paymentRequestId: String
    let counterparty: String
    let counterpartyReceiverPath: String
    let amountValue: String
    let amountSats: UInt64
    let expiresAt: Date?
    let acceptedPaymentEndpointIdentifiers: [String]

    var id: ID {
        ID(
            paymentRequestId: paymentRequestId,
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath
        )
    }

    init?(record: Paykit.PaymentRequestRecord, now: Date) {
        guard record.localRole == .payer,
              record.state == .proposed,
              let terms = record.terms,
              terms.recurrence == nil,
              terms.amount.asset == "btc",
              let amountSats = Self.sats(fromBitcoinAmount: terms.amount.value),
              amountSats <= UInt64.max / 1000
        else { return nil }

        let acceptedPaymentEndpointIdentifiers = Self.supportedEndpointIdentifiers(
            terms.acceptedPaymentEndpointIdentifiers
        )
        guard !acceptedPaymentEndpointIdentifiers.isEmpty else { return nil }

        let expiresAt: Date?
        if let proposalExpiresAt = terms.proposalExpiresAt {
            guard let parsedExpiration = Self.parseDate(proposalExpiresAt), parsedExpiration > now else {
                return nil
            }
            expiresAt = parsedExpiration
        } else {
            expiresAt = nil
        }

        paymentRequestId = record.paymentRequestId
        counterparty = record.counterparty
        counterpartyReceiverPath = record.counterpartyReceiverPath
        amountValue = terms.amount.value
        self.amountSats = amountSats
        self.expiresAt = expiresAt
        self.acceptedPaymentEndpointIdentifiers = acceptedPaymentEndpointIdentifiers
    }

    func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }

    func acceptsLightningInvoiceAmount(milliSatoshis: UInt64?) -> Bool {
        guard let milliSatoshis else { return true }
        let (requestedMilliSatoshis, overflow) = amountSats.multipliedReportingOverflow(by: 1000)
        return !overflow && milliSatoshis == requestedMilliSatoshis
    }

    func acceptsPaymentAmount(_ amountSats: UInt64) -> Bool {
        amountSats == self.amountSats
    }

    private static func supportedEndpointIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { identifier in
            guard seen.insert(identifier).inserted,
                  let methodId = PublicPaykitService.MethodId(rawValue: identifier)
            else { return false }

            if let network = methodId.onchainNetwork {
                return network == Env.network
            }

            return methodId == .bitcoinLightningBolt11 || methodId == .bitcoinLightningLnurl
        }
    }

    private static func sats(fromBitcoinAmount amount: String) -> UInt64? {
        let components = amount.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let digits = components.joined()
        guard digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              !digits.isEmpty
        else { return nil }

        let wholeBtc = components[0].isEmpty ? 0 : UInt64(components[0])
        guard let wholeBtc else { return nil }

        var fraction = components.count == 2 ? String(components[1]) : ""
        while fraction.last == "0" {
            fraction.removeLast()
        }
        guard fraction.count <= 8 else { return nil }

        let fractionSats = UInt64(fraction.padding(toLength: 8, withPad: "0", startingAt: 0)) ?? 0
        let (wholeSats, wholeOverflow) = wholeBtc.multipliedReportingOverflow(by: 100_000_000)
        let (amountSats, totalOverflow) = wholeSats.addingReportingOverflow(fractionSats)
        guard !wholeOverflow, !totalOverflow, amountSats > 0 else { return nil }
        return amountSats
    }

    private static func parseDate(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

enum PaykitPaymentRequestError: LocalizedError, Equatable {
    case requestUnavailable
    case requestExpired
    case operationInProgress
    case amountMismatch

    var errorDescription: String? {
        switch self {
        case .requestUnavailable:
            t("wallet__payment_request_unavailable")
        case .requestExpired:
            t("wallet__payment_request_expired")
        case .operationInProgress:
            t("wallet__payment_request_in_progress")
        case .amountMismatch:
            t("wallet__payment_request_mismatch")
        }
    }
}

protocol PaykitPaymentRequestSdkHandling: Sendable {
    func processPendingPrivateMessages() async throws -> [Paykit.OutboundPrivateCounterpartySendReport]
    func receivePrivateMessagesFromLinkedPeers() async throws -> [Paykit.PrivateStreamCounterpartyIntakeReport]
    func actionableReceivedPaymentRequests() async throws -> [Paykit.PaymentRequestRecord]
    func acceptPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String
    ) async throws -> Paykit.PaymentRequestRecord
}

extension PaykitSdkService: PaykitPaymentRequestSdkHandling {}

struct PaykitPaymentRequestService {
    private let sdk: any PaykitPaymentRequestSdkHandling
    private let now: @Sendable () -> Date
    private let logWarning: @Sendable (String) -> Void

    init(
        sdk: any PaykitPaymentRequestSdkHandling = PaykitSdkService.shared,
        now: @escaping @Sendable () -> Date = { Date() },
        logWarning: @escaping @Sendable (String) -> Void = {
            Logger.warn($0, context: "PaykitPaymentRequest")
        }
    ) {
        self.sdk = sdk
        self.now = now
        self.logWarning = logWarning
    }

    func synchronize() async throws -> [PaykitPaymentRequest] {
        try await processPendingMessages()
        let intakeReports = try await sdk.receivePrivateMessagesFromLinkedPeers()
        logIntakeFailures(intakeReports)
        let synchronizationDate = now()
        return try await sdk.actionableReceivedPaymentRequests().compactMap {
            PaykitPaymentRequest(record: $0, now: synchronizationDate)
        }
    }

    func accept(_ request: PaykitPaymentRequest) async throws {
        guard !request.isExpired(at: now()) else {
            throw PaykitPaymentRequestError.requestExpired
        }

        _ = try await sdk.acceptPaymentRequest(
            counterparty: request.counterparty,
            counterpartyReceiverPath: request.counterpartyReceiverPath,
            paymentRequestId: request.paymentRequestId
        )
        try? await processPendingMessages()
    }

    private func processPendingMessages() async throws {
        do {
            let reports = try await sdk.processPendingPrivateMessages()
            for report in reports {
                guard let error = report.error else { continue }
                logWarning(
                    "Failed to deliver Paykit private messages to \(PubkyPublicKeyFormat.redacted(report.counterparty)): \(error.redactedContext())"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logWarning("Failed to deliver pending Paykit private messages: \(error)")
        }
    }

    private func logIntakeFailures(_ reports: [Paykit.PrivateStreamCounterpartyIntakeReport]) {
        for report in reports {
            guard let error = report.error else { continue }
            logWarning(
                "Failed to receive Paykit private messages from \(PubkyPublicKeyFormat.redacted(report.counterparty)): \(error.redactedContext())"
            )
        }
    }
}

@Observable
@MainActor
final class PaykitPaymentRequestManager {
    private static let presentationRetryDelays: [TimeInterval] = [30, 60, 120, 300]

    private(set) var pendingRequests: [PaykitPaymentRequest] = []

    private let service: PaykitPaymentRequestService
    private let now: @Sendable () -> Date
    private let logWarning: @Sendable (String) -> Void
    private var processingRequestIds: Set<PaykitPaymentRequest.ID> = []
    private var presentedRequestIds: Set<PaykitPaymentRequest.ID> = []
    private var presentationRetryAttempts: [PaykitPaymentRequest.ID: Int] = [:]
    private var presentationRetryDates: [PaykitPaymentRequest.ID: Date] = [:]
    private var isPresentingRequests = false
    private var refreshTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var stateGeneration = 0

    init(
        service: PaykitPaymentRequestService? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        logWarning: @escaping @Sendable (String) -> Void = {
            Logger.warn($0, context: "PaykitPaymentRequest")
        }
    ) {
        self.service = service ?? PaykitPaymentRequestService(now: now, logWarning: logWarning)
        self.now = now
        self.logWarning = logWarning
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await performRefresh(generation: generation)
        }
        refreshTask = task
        await task.value

        guard generation == refreshGeneration else { return }
        refreshTask = nil
    }

    func prepareForPayment(
        _ request: PaykitPaymentRequest,
        consumePrivatePaymentList: () async throws -> Void = {}
    ) async throws {
        do {
            try await perform(request) {
                try await consumePrivatePaymentList()
                try await service.accept($0)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            deferPresentation(request)
            throw error
        }
    }

    func clear() {
        stateGeneration += 1
        invalidateRefresh()
        expirationTask?.cancel()
        expirationTask = nil
        pendingRequests = []
        processingRequestIds = []
        presentedRequestIds = []
        presentationRetryAttempts = [:]
        presentationRetryDates = [:]
        isPresentingRequests = false
    }

    func requestsForPresentation() -> [PaykitPaymentRequest] {
        let date = now()
        return pendingRequests.filter {
            !presentedRequestIds.contains($0.id) &&
                presentationRetryAttempts[$0.id, default: 0] <= Self.presentationRetryDelays.count &&
                (presentationRetryDates[$0.id].map { $0 <= date } ?? true)
        }
    }

    func presentRequests(_ operation: ([PaykitPaymentRequest]) async -> Void) async {
        guard !isPresentingRequests else { return }
        let requests = requestsForPresentation()
        guard !requests.isEmpty else { return }

        isPresentingRequests = true
        defer { isPresentingRequests = false }
        await operation(requests)
    }

    func deferPresentation(_ request: PaykitPaymentRequest) {
        discardExpiredRequests()
        guard pendingRequests.contains(where: { $0.id == request.id }) else { return }

        presentedRequestIds.remove(request.id)
        let attempt = presentationRetryAttempts[request.id, default: 0]
        presentationRetryAttempts[request.id] = attempt + 1
        guard attempt < Self.presentationRetryDelays.count else {
            presentationRetryDates.removeValue(forKey: request.id)
            logWarning("Stopped retrying incoming Paykit payment request after \(attempt + 1) presentation attempts")
            return
        }
        let delay = Self.presentationRetryDelays[attempt]
        presentationRetryDates[request.id] = now().addingTimeInterval(delay)
    }

    func markPresentedIfPending(_ request: PaykitPaymentRequest) -> Bool {
        discardExpiredRequests()
        guard pendingRequests.contains(where: { $0.id == request.id }) else { return false }
        presentedRequestIds.insert(request.id)
        presentationRetryAttempts.removeValue(forKey: request.id)
        presentationRetryDates.removeValue(forKey: request.id)
        return true
    }

    private func performRefresh(generation: Int) async {
        do {
            let requests = try await service.synchronize()
            guard generation == refreshGeneration else { return }
            pendingRequests = requests
            let requestIds = Set(requests.map(\.id))
            presentedRequestIds.formIntersection(requestIds)
            presentationRetryAttempts = presentationRetryAttempts.filter { requestIds.contains($0.key) }
            presentationRetryDates = presentationRetryDates.filter { requestIds.contains($0.key) }
            discardExpiredRequests()
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            discardExpiredRequests()
            logWarning("Failed to refresh incoming Paykit payment requests: \(error)")
        }
    }

    private func perform(
        _ request: PaykitPaymentRequest,
        operation: (PaykitPaymentRequest) async throws -> Void
    ) async throws {
        guard !request.isExpired(at: now()) else {
            discardExpiredRequests()
            throw PaykitPaymentRequestError.requestExpired
        }
        guard pendingRequests.contains(where: { $0.id == request.id }) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        let actionGeneration = stateGeneration
        guard processingRequestIds.insert(request.id).inserted else {
            throw PaykitPaymentRequestError.operationInProgress
        }
        defer {
            if actionGeneration == stateGeneration {
                processingRequestIds.remove(request.id)
            }
        }

        do {
            try await operation(request)
            guard actionGeneration == stateGeneration else { return }
            invalidateRefresh()
            pendingRequests.removeAll { $0.id == request.id }
            presentationRetryAttempts.removeValue(forKey: request.id)
            presentationRetryDates.removeValue(forKey: request.id)
            discardExpiredRequests()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard actionGeneration == stateGeneration else { throw error }
            invalidateRefresh()
            await refresh()
            throw error
        }
    }

    private func invalidateRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func discardExpiredRequests() {
        pendingRequests.removeAll { $0.isExpired(at: now()) }
        let requestIds = Set(pendingRequests.map(\.id))
        presentedRequestIds.formIntersection(requestIds)
        presentationRetryAttempts = presentationRetryAttempts.filter { requestIds.contains($0.key) }
        presentationRetryDates = presentationRetryDates.filter { requestIds.contains($0.key) }
        scheduleExpiration()
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        expirationTask = nil

        guard let nextExpiration = pendingRequests.compactMap(\.expiresAt).min() else { return }
        let delay = max(0, nextExpiration.timeIntervalSince(now()))
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.discardExpiredRequests()
        }
    }
}
