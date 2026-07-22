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
    let paymentReference: String
    let expiresAt: Date?
    let acceptedPaymentEndpointIdentifiers: [String]
    let metadata: String

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
              let amountSats = Self.sats(fromBitcoinAmount: terms.amount.value)
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
        paymentReference = terms.paymentReference.exportText()
        self.expiresAt = expiresAt
        self.acceptedPaymentEndpointIdentifiers = acceptedPaymentEndpointIdentifiers
        metadata = terms.metadata.exportText()
    }

    func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
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

enum PaykitPaymentRequestError: Error, Equatable {
    case requestUnavailable
    case requestExpired
    case operationInProgress
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
    private(set) var pendingRequests: [PaykitPaymentRequest] = []

    private let service: PaykitPaymentRequestService
    private let now: @Sendable () -> Date
    private let logWarning: @Sendable (String) -> Void
    private var processingRequestIds: Set<PaykitPaymentRequest.ID> = []
    private var presentedRequestIds: Set<PaykitPaymentRequest.ID> = []
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

    func accept(_ request: PaykitPaymentRequest) async throws {
        try await perform(request) {
            try await service.accept($0)
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
    }

    func nextRequestForPresentation() -> PaykitPaymentRequest? {
        pendingRequests.first { !presentedRequestIds.contains($0.id) }
    }

    func markPresented(_ request: PaykitPaymentRequest) {
        guard pendingRequests.contains(where: { $0.id == request.id }) else { return }
        presentedRequestIds.insert(request.id)
    }

    private func performRefresh(generation: Int) async {
        do {
            let requests = try await service.synchronize()
            guard generation == refreshGeneration else { return }
            pendingRequests = requests
            presentedRequestIds.formIntersection(requests.map(\.id))
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
        presentedRequestIds.formIntersection(pendingRequests.map(\.id))
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
