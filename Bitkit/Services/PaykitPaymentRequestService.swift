import Foundation
import Paykit

struct PaykitPaymentRequest: Identifiable, Hashable {
    enum Direction: Hashable {
        case incoming
        case outgoing
    }

    enum DeliveryStatus: Hashable {
        case queued
        case sent
    }

    struct ID: Codable, Hashable {
        let paymentRequestId: String
        let counterparty: String
        let counterpartyReceiverPath: String
    }

    let paymentRequestId: String
    let counterparty: String
    let counterpartyReceiverPath: String
    let amountValue: String
    let amountSats: UInt64
    let note: String?
    let createdAt: Date?
    let expiresAt: Date?
    let acceptedPaymentEndpointIdentifiers: [String]
    let deliveryStatus: DeliveryStatus?
    let direction: Direction
    let lifecycleState: Paykit.PaymentRequestLifecycleState

    var id: ID {
        ID(
            paymentRequestId: paymentRequestId,
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath
        )
    }

    init?(record: Paykit.PaymentRequestRecord, now: Date) {
        self.init(record: record, expectedRole: .payer, now: now, requiresActionableRequest: true)
    }

    init?(historyRecord: Paykit.PaymentRequestRecord, now: Date) {
        guard let localRole = historyRecord.localRole else { return nil }
        switch localRole {
        case .payer, .payee:
            self.init(record: historyRecord, expectedRole: localRole, now: now, requiresActionableRequest: false)
        case .unknown:
            return nil
        }
    }

    private init?(
        record: Paykit.PaymentRequestRecord,
        expectedRole: Paykit.PaymentRequestLocalRole,
        now: Date,
        requiresActionableRequest: Bool
    ) {
        guard record.localRole == expectedRole,
              record.state != .activeRecurring,
              let terms = record.terms,
              terms.recurrence == nil,
              terms.amount.asset == "btc",
              let amountSats = Self.sats(fromBitcoinAmount: terms.amount.value),
              amountSats <= UInt64.max / 1000
        else { return nil }

        if requiresActionableRequest, record.state != .proposed {
            return nil
        }

        let acceptedPaymentEndpointIdentifiers = Self.supportedEndpointIdentifiers(
            terms.acceptedPaymentEndpointIdentifiers
        )
        if requiresActionableRequest, acceptedPaymentEndpointIdentifiers.isEmpty {
            return nil
        }

        let expiresAt: Date?
        if let proposalExpiresAt = terms.proposalExpiresAt {
            guard let parsedExpiration = Self.parseDate(proposalExpiresAt),
                  !requiresActionableRequest || parsedExpiration > now
            else {
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
        note = Self.note(from: terms.metadata)
        createdAt = record.lastEventAt.flatMap(Self.parseDate)
        self.expiresAt = expiresAt
        self.acceptedPaymentEndpointIdentifiers = acceptedPaymentEndpointIdentifiers
        deliveryStatus = expectedRole == .payee ? Self.deliveryStatus(from: record.proposalOutboundStatus) : nil
        direction = expectedRole == .payer ? .incoming : .outgoing
        lifecycleState = record.state
    }

    init(
        createdRecord: Paykit.PaymentRequestRecord,
        draft: PaykitPaymentRequestDraft,
        target: PaykitPaymentRequestTarget,
        acceptedPaymentEndpointIdentifiers: [String],
        deliveryStatus: DeliveryStatus,
        createdAt fallbackCreatedAt: Date
    ) {
        paymentRequestId = createdRecord.paymentRequestId
        counterparty = target.publicKey
        counterpartyReceiverPath = target.receiverPath
        amountValue = WalletViewModel.formatBitcoinAmount(sats: draft.amountSats)
        amountSats = draft.amountSats
        let trimmedNote = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = trimmedNote.isEmpty ? nil : trimmedNote
        createdAt = createdRecord.lastEventAt.flatMap(Self.parseDate) ?? fallbackCreatedAt
        expiresAt = draft.expiresAt
        self.acceptedPaymentEndpointIdentifiers = acceptedPaymentEndpointIdentifiers
        self.deliveryStatus = deliveryStatus
        direction = .outgoing
        lifecycleState = .proposed
    }

    func updatingLifecycleState(_ state: Paykit.PaymentRequestLifecycleState) -> PaykitPaymentRequest {
        PaykitPaymentRequest(
            paymentRequestId: paymentRequestId,
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            amountValue: amountValue,
            amountSats: amountSats,
            note: note,
            createdAt: createdAt,
            expiresAt: expiresAt,
            acceptedPaymentEndpointIdentifiers: acceptedPaymentEndpointIdentifiers,
            deliveryStatus: deliveryStatus,
            direction: direction,
            lifecycleState: state
        )
    }

    private init(
        paymentRequestId: String,
        counterparty: String,
        counterpartyReceiverPath: String,
        amountValue: String,
        amountSats: UInt64,
        note: String?,
        createdAt: Date?,
        expiresAt: Date?,
        acceptedPaymentEndpointIdentifiers: [String],
        deliveryStatus: DeliveryStatus?,
        direction: Direction,
        lifecycleState: Paykit.PaymentRequestLifecycleState
    ) {
        self.paymentRequestId = paymentRequestId
        self.counterparty = counterparty
        self.counterpartyReceiverPath = counterpartyReceiverPath
        self.amountValue = amountValue
        self.amountSats = amountSats
        self.note = note
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.acceptedPaymentEndpointIdentifiers = acceptedPaymentEndpointIdentifiers
        self.deliveryStatus = deliveryStatus
        self.direction = direction
        self.lifecycleState = lifecycleState
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

    private static func note(from metadata: Paykit.PrivateJsonObject) -> String? {
        guard let data = metadata.exportText().data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let note = object["note"] as? String
        else { return nil }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNote.isEmpty ? nil : trimmedNote
    }

    private static func deliveryStatus(from status: Paykit.OutboundPrivateMessageStatus?) -> DeliveryStatus {
        if case .sent? = status {
            return .sent
        }
        return .queued
    }
}

struct PaykitPaymentRequestTarget: Identifiable, Equatable, Hashable {
    let publicKey: String
    let receiverPath: String

    var id: String {
        "\(publicKey)|\(receiverPath)"
    }
}

struct PaykitPaymentRequestDraft: Hashable {
    let amountSats: UInt64
    let note: String
    let expiresAt: Date
}

struct PaykitPaymentRequestSnapshot: Equatable {
    let incoming: [PaykitPaymentRequest]
    let history: [PaykitPaymentRequest]
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
    func paymentRequests() async throws -> [Paykit.PaymentRequestRecord]
    func identityStatus() async throws -> Paykit.IdentityStatus?
    func linkedPeers() async throws -> [Paykit.LinkedPeerRecord]
    func paymentRequestReceiverPaths(publicKey: String) async throws -> [String]
    func proposePaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        terms: Paykit.PaymentRequestTerms,
        expectedIdentity: String
    ) async throws -> Paykit.PaymentRequestRecord
    func acceptPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String
    ) async throws -> Paykit.PaymentRequestRecord
    func rejectPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String,
        reason: String?
    ) async throws -> Paykit.PaymentRequestRecord
}

extension PaykitSdkService: PaykitPaymentRequestSdkHandling {}

struct PaykitPaymentRequestService {
    private let sdk: any PaykitPaymentRequestSdkHandling
    private let now: @Sendable () -> Date
    private let isPrivatePaymentPublishingEnabled: @Sendable () -> Bool
    private let logWarning: @Sendable (String) -> Void

    init(
        sdk: any PaykitPaymentRequestSdkHandling = PaykitSdkService.shared,
        now: @escaping @Sendable () -> Date = { Date() },
        isPrivatePaymentPublishingEnabled: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey)
        },
        logWarning: @escaping @Sendable (String) -> Void = {
            Logger.warn($0, context: "PaykitPaymentRequest")
        }
    ) {
        self.sdk = sdk
        self.now = now
        self.isPrivatePaymentPublishingEnabled = isPrivatePaymentPublishingEnabled
        self.logWarning = logWarning
    }

    func synchronize() async throws -> PaykitPaymentRequestSnapshot {
        try await processPendingMessages()
        let intakeReports = try await sdk.receivePrivateMessagesFromLinkedPeers()
        logIntakeFailures(intakeReports)
        let synchronizationDate = now()
        let records = try await sdk.paymentRequests()
        let incoming = records.compactMap {
            PaykitPaymentRequest(record: $0, now: synchronizationDate)
        }
        let history = records.compactMap {
            PaykitPaymentRequest(historyRecord: $0, now: synchronizationDate)
        }
        return PaykitPaymentRequestSnapshot(incoming: incoming, history: history)
    }

    func eligibleTargets(savedPublicKeys: [String], expectedIdentity: String) async throws -> [PaykitPaymentRequestTarget] {
        guard isPrivatePaymentPublishingEnabled(), !Self.acceptedPaymentEndpointIdentifiers().isEmpty else { return [] }
        guard let identityStatus = try await sdk.identityStatus(),
              identityStatus.liveSessionAvailable,
              PubkyPublicKeyFormat.matches(identityStatus.publicKey, expectedIdentity)
        else { return [] }
        var seenSavedKeys = Set<String>()
        let savedKeys = savedPublicKeys.compactMap(PubkyPublicKeyFormat.normalized).filter {
            seenSavedKeys.insert($0).inserted
        }
        let linkedPeers = try await sdk.linkedPeers().filter { $0.state == .linked }
        var linkedPathsByPublicKey: [String: Set<String>] = [:]

        for peer in linkedPeers {
            guard let publicKey = PubkyPublicKeyFormat.normalized(peer.counterparty),
                  PaykitReceiverPath.supported.contains(peer.counterpartyReceiverPath)
            else { continue }
            linkedPathsByPublicKey[publicKey, default: []].insert(peer.counterpartyReceiverPath)
        }

        var targets: [PaykitPaymentRequestTarget] = []
        for publicKey in savedKeys {
            guard let linkedPaths = linkedPathsByPublicKey[publicKey] else { continue }
            let capablePaths: [String]
            do {
                capablePaths = try await sdk.paymentRequestReceiverPaths(publicKey: publicKey)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logWarning("Failed to inspect Paykit payment request support for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)")
                continue
            }
            guard let receiverPath = PaykitReceiverPath.supported.first(where: {
                linkedPaths.contains($0) && capablePaths.contains($0)
            }) else { continue }

            targets.append(PaykitPaymentRequestTarget(publicKey: publicKey, receiverPath: receiverPath))
        }
        return targets
    }

    func propose(
        _ draft: PaykitPaymentRequestDraft,
        to target: PaykitPaymentRequestTarget,
        savedPublicKeys: [String],
        expectedIdentity: String
    ) async throws -> PaykitPaymentRequest {
        let acceptedPaymentEndpointIdentifiers = Self.acceptedPaymentEndpointIdentifiers()
        let proposalDate = now()
        guard draft.amountSats > 0, !acceptedPaymentEndpointIdentifiers.isEmpty else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        guard draft.expiresAt > proposalDate else {
            throw PaykitPaymentRequestError.requestExpired
        }
        guard try await eligibleTargets(savedPublicKeys: savedPublicKeys, expectedIdentity: expectedIdentity).contains(target) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        let metadataData = try JSONSerialization.data(withJSONObject: ["note": draft.note])
        let metadataText = String(decoding: metadataData, as: UTF8.self)
        let terms = try Paykit.PaymentRequestTerms(
            amount: Paykit.PaymentRequestAmount(value: WalletViewModel.formatBitcoinAmount(sats: draft.amountSats), asset: "btc"),
            paymentReference: Paykit.PaymentReference(text: "bitkit-\(UUID().uuidString)"),
            proposalExpiresAt: Self.timestamp(draft.expiresAt),
            recurrence: nil,
            acceptedPaymentEndpointIdentifiers: acceptedPaymentEndpointIdentifiers,
            metadata: Paykit.PrivateJsonObject(text: metadataText)
        )
        let record = try await sdk.proposePaymentRequest(
            counterparty: target.publicKey,
            counterpartyReceiverPath: target.receiverPath,
            terms: terms,
            expectedIdentity: expectedIdentity
        )
        let reports = await (try? processPendingMessages()) ?? []
        let deliveryStatus = proposalWasSent(record, reports: reports) ? PaykitPaymentRequest.DeliveryStatus.sent : .queued
        return PaykitPaymentRequest(
            createdRecord: record,
            draft: draft,
            target: target,
            acceptedPaymentEndpointIdentifiers: acceptedPaymentEndpointIdentifiers,
            deliveryStatus: deliveryStatus,
            createdAt: proposalDate
        )
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
        _ = try? await processPendingMessages()
    }

    func reject(_ request: PaykitPaymentRequest) async throws {
        guard !request.isExpired(at: now()) else {
            throw PaykitPaymentRequestError.requestExpired
        }

        _ = try await sdk.rejectPaymentRequest(
            counterparty: request.counterparty,
            counterpartyReceiverPath: request.counterpartyReceiverPath,
            paymentRequestId: request.paymentRequestId,
            reason: nil
        )
        _ = try? await processPendingMessages()
    }

    private static func acceptedPaymentEndpointIdentifiers() -> [String] {
        PublicPaykitService.MethodId.publishableMethodIds.compactMap { methodId in
            if methodId == .bitcoinLightningBolt11 {
                return PublicPaykitService.isLightningPaymentOptionEnabled() ? methodId.rawValue : nil
            }
            guard methodId.onchainNetwork == Env.network,
                  PublicPaykitService.isOnchainPaymentOptionEnabled()
            else { return nil }
            return methodId.rawValue
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @discardableResult
    private func processPendingMessages() async throws -> [Paykit.OutboundPrivateCounterpartySendReport] {
        do {
            let reports = try await sdk.processPendingPrivateMessages()
            for report in reports {
                if let error = report.error {
                    logWarning(
                        "Failed to deliver Paykit private messages to \(PubkyPublicKeyFormat.redacted(report.counterparty)): \(error.redactedContext())"
                    )
                }
                for failure in report.report?.failed ?? [] {
                    logWarning(
                        "Failed to deliver Paykit private message \(failure.outboundMessageId) to " +
                            "\(PubkyPublicKeyFormat.redacted(report.counterparty)): \(failure.error.redactedContext())"
                    )
                }
            }
            return reports
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logWarning("Failed to deliver pending Paykit private messages: \(error)")
            return []
        }
    }

    private func proposalWasSent(
        _ record: Paykit.PaymentRequestRecord,
        reports: [Paykit.OutboundPrivateCounterpartySendReport]
    ) -> Bool {
        guard let messageId = record.proposalOutboundMessageId else { return false }
        return reports.contains { report in
            PubkyPublicKeyFormat.matches(report.counterparty, record.counterparty) &&
                report.counterpartyReceiverPath == record.counterpartyReceiverPath &&
                report.report?.sent.contains(messageId) == true
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

protocol PaykitPaymentRequestPresentationStoring {
    func load(identity: String) throws -> Set<PaykitPaymentRequest.ID>
    func save(_ ids: Set<PaykitPaymentRequest.ID>, identity: String) throws
}

struct PaykitPaymentRequestPresentationStore: PaykitPaymentRequestPresentationStoring {
    private struct State: Codable {
        var idsByIdentity: [String: [PaykitPaymentRequest.ID]]
    }

    func load(identity: String) throws -> Set<PaykitPaymentRequest.ID> {
        guard let data = try Keychain.load(key: .paykitPresentedPaymentRequests) else { return [] }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard let normalizedIdentity = PubkyPublicKeyFormat.normalized(identity) else { return [] }
        return Set(state.idsByIdentity[normalizedIdentity] ?? [])
    }

    func save(_ ids: Set<PaykitPaymentRequest.ID>, identity: String) throws {
        guard let normalizedIdentity = PubkyPublicKeyFormat.normalized(identity) else { return }
        var state: State = if let data = try Keychain.load(key: .paykitPresentedPaymentRequests) {
            try JSONDecoder().decode(State.self, from: data)
        } else {
            State(idsByIdentity: [:])
        }
        state.idsByIdentity[normalizedIdentity] = Array(ids)
        try Keychain.upsert(key: .paykitPresentedPaymentRequests, data: JSONEncoder().encode(state))
    }
}

@Observable
@MainActor
final class PaykitPaymentRequestManager {
    private static let presentationRetryDelays = Array(repeating: TimeInterval(2), count: 14)

    private(set) var pendingRequests: [PaykitPaymentRequest] = []
    private(set) var historyRequests: [PaykitPaymentRequest] = []
    private(set) var eligibleTargets: [PaykitPaymentRequestTarget] = []
    private(set) var requestedPresentationId: PaykitPaymentRequest.ID?
    private(set) var isCreatingRequest = false
    private(set) var presentationRetryTrigger = 0

    private let service: PaykitPaymentRequestService
    private let presentationStore: any PaykitPaymentRequestPresentationStoring
    private let now: @Sendable () -> Date
    private let logWarning: @Sendable (String) -> Void
    private let isAvailable: @MainActor () -> Bool
    private var processingRequestIds: Set<PaykitPaymentRequest.ID> = []
    private var approvedPaymentRequestIds: Set<PaykitPaymentRequest.ID> = []
    private var presentedRequestIds: Set<PaykitPaymentRequest.ID> = []
    private var presentationRetryAttempts: [PaykitPaymentRequest.ID: Int] = [:]
    private var presentationRetryDates: [PaykitPaymentRequest.ID: Date] = [:]
    private var isPresentingRequests = false
    private var refreshTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var presentationRetryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var eligibilityGeneration = 0
    private var stateGeneration = 0
    private var presentationGeneration = 0
    private var activePresentationGeneration: Int?
    private var activeIdentity: String?
    private var savedPublicKeys: [String] = []
    private var persistedPresentedRequestIds: Set<PaykitPaymentRequest.ID> = []

    var outgoingRequests: [PaykitPaymentRequest] {
        historyRequests.filter { $0.direction == .outgoing }
    }

    init(
        service: PaykitPaymentRequestService? = nil,
        presentationStore: any PaykitPaymentRequestPresentationStoring = PaykitPaymentRequestPresentationStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        isAvailable: @escaping @MainActor () -> Bool = { PaykitFeatureFlags.isUIEnabled },
        logWarning: @escaping @Sendable (String) -> Void = {
            Logger.warn($0, context: "PaykitPaymentRequest")
        }
    ) {
        self.service = service ?? PaykitPaymentRequestService(now: now, logWarning: logWarning)
        self.presentationStore = presentationStore
        self.now = now
        self.isAvailable = isAvailable
        self.logWarning = logWarning
    }

    func activate(identity: String) {
        guard let normalizedIdentity = PubkyPublicKeyFormat.normalized(identity) else { return }
        guard !PubkyPublicKeyFormat.matches(activeIdentity, normalizedIdentity) else { return }
        if activeIdentity != nil {
            clear()
        }
        activeIdentity = normalizedIdentity
        do {
            presentedRequestIds = try presentationStore.load(identity: normalizedIdentity)
            persistedPresentedRequestIds = presentedRequestIds
        } catch {
            presentedRequestIds = []
            persistedPresentedRequestIds = []
            logWarning("Failed to restore surfaced Paykit payment requests: \(error)")
        }
    }

    func refreshEligibleTargets(savedPublicKeys: [String]) async {
        eligibilityGeneration += 1
        let generation = eligibilityGeneration
        let currentStateGeneration = stateGeneration
        self.savedPublicKeys = savedPublicKeys
        guard isAvailable(), let activeIdentity else {
            eligibleTargets = []
            return
        }

        do {
            let targets = try await service.eligibleTargets(savedPublicKeys: savedPublicKeys, expectedIdentity: activeIdentity)
            guard generation == eligibilityGeneration,
                  currentStateGeneration == stateGeneration,
                  savedPublicKeys == self.savedPublicKeys,
                  isAvailable(),
                  PubkyPublicKeyFormat.matches(self.activeIdentity, activeIdentity)
            else { return }
            eligibleTargets = targets
        } catch is CancellationError {
            return
        } catch {
            guard generation == eligibilityGeneration,
                  currentStateGeneration == stateGeneration
            else { return }
            eligibleTargets = []
            logWarning("Failed to refresh Paykit payment request recipients: \(error)")
        }
    }

    func clearEligibleTargets() {
        eligibilityGeneration += 1
        savedPublicKeys = []
        eligibleTargets = []
    }

    func propose(_ draft: PaykitPaymentRequestDraft, to target: PaykitPaymentRequestTarget) async throws -> PaykitPaymentRequest {
        guard draft.amountSats > 0,
              isAvailable(),
              let activeIdentity,
              eligibleTargets.contains(target)
        else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        guard !isCreatingRequest else {
            throw PaykitPaymentRequestError.operationInProgress
        }

        let actionGeneration = stateGeneration
        let savedPublicKeysSnapshot = savedPublicKeys
        isCreatingRequest = true
        defer {
            if actionGeneration == stateGeneration {
                isCreatingRequest = false
            }
        }
        let request = try await service.propose(
            draft,
            to: target,
            savedPublicKeys: savedPublicKeysSnapshot,
            expectedIdentity: activeIdentity
        )
        if actionGeneration == stateGeneration,
           isAvailable(),
           PubkyPublicKeyFormat.matches(self.activeIdentity, activeIdentity),
           savedPublicKeysSnapshot == savedPublicKeys
        {
            invalidateRefresh()
            historyRequests.removeAll { $0.id == request.id }
            historyRequests.insert(request, at: 0)
            discardExpiredRequests()
        }
        return request
    }

    func refresh() async {
        await refresh(excludingProtectedRequestId: nil)
    }

    private func refresh(excludingProtectedRequestId: PaykitPaymentRequest.ID?) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await performRefresh(generation: generation, excludingProtectedRequestId: excludingProtectedRequestId)
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
            try await perform(request, resultingState: .accepted, markApprovedForPayment: true) {
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

    func reject(_ request: PaykitPaymentRequest) async throws {
        guard requestedPresentationId != request.id else {
            throw PaykitPaymentRequestError.operationInProgress
        }
        try await perform(request, resultingState: .rejected) {
            try await service.reject($0)
        }
    }

    @discardableResult
    func requestPresentation(_ request: PaykitPaymentRequest) -> Bool {
        discardExpiredRequests()
        guard pendingRequests.contains(where: { $0.id == request.id }),
              !processingRequestIds.contains(request.id),
              requestedPresentationId == nil
        else { return false }
        presentationGeneration += 1
        presentationRetryAttempts.removeValue(forKey: request.id)
        presentationRetryDates.removeValue(forKey: request.id)
        requestedPresentationId = request.id
        schedulePresentationRetry()
        return true
    }

    func clear() {
        stateGeneration += 1
        presentationGeneration += 1
        invalidateRefresh()
        eligibilityGeneration += 1
        expirationTask?.cancel()
        expirationTask = nil
        presentationRetryTask?.cancel()
        presentationRetryTask = nil
        pendingRequests = []
        historyRequests = []
        eligibleTargets = []
        processingRequestIds = []
        approvedPaymentRequestIds = []
        activeIdentity = nil
        savedPublicKeys = []
        presentedRequestIds = []
        persistedPresentedRequestIds = []
        presentationRetryAttempts = [:]
        presentationRetryDates = [:]
        requestedPresentationId = nil
        isCreatingRequest = false
    }

    func requestsForPresentation() -> [PaykitPaymentRequest] {
        let date = now()
        if let requestedPresentationId {
            guard !processingRequestIds.contains(requestedPresentationId),
                  let requestedRequest = pendingRequests.first(where: { $0.id == requestedPresentationId }),
                  presentationRetryAttempts[requestedPresentationId, default: 0] <= Self.presentationRetryDelays.count,
                  presentationRetryDates[requestedPresentationId].map({ $0 <= date }) ?? true
            else { return [] }
            return [requestedRequest]
        }

        return pendingRequests.filter {
            !presentedRequestIds.contains($0.id) &&
                !processingRequestIds.contains($0.id) &&
                presentationRetryAttempts[$0.id, default: 0] <= Self.presentationRetryDelays.count &&
                (presentationRetryDates[$0.id].map { $0 <= date } ?? true)
        }
    }

    @discardableResult
    func presentRequests(_ operation: ([PaykitPaymentRequest]) async -> Void) async -> Bool {
        guard !isPresentingRequests else { return false }
        let requests = requestsForPresentation()
        guard !requests.isEmpty else { return false }

        isPresentingRequests = true
        activePresentationGeneration = presentationGeneration
        defer {
            isPresentingRequests = false
            activePresentationGeneration = nil
        }
        await operation(requests)
        return true
    }

    func isCurrentPresentation(_ request: PaykitPaymentRequest) -> Bool {
        guard isPresentingRequests,
              activePresentationGeneration == presentationGeneration,
              pendingRequests.contains(where: { $0.id == request.id }),
              !processingRequestIds.contains(request.id)
        else { return false }

        return requestedPresentationId.map { $0 == request.id } ?? true
    }

    func isApprovedForPayment(_ request: PaykitPaymentRequest) -> Bool {
        approvedPaymentRequestIds.contains(request.id)
    }

    func finishPayment(_ request: PaykitPaymentRequest) {
        approvedPaymentRequestIds.remove(request.id)
    }

    func deferPresentation(_ request: PaykitPaymentRequest) {
        discardExpiredRequests()
        guard pendingRequests.contains(where: { $0.id == request.id }) else { return }

        let isRequestedPresentation = requestedPresentationId == request.id
        presentationGeneration += 1
        if !isRequestedPresentation {
            presentedRequestIds.remove(request.id)
        }
        let attempt = presentationRetryAttempts[request.id, default: 0]
        presentationRetryAttempts[request.id] = attempt + 1
        guard attempt < Self.presentationRetryDelays.count else {
            presentationRetryDates.removeValue(forKey: request.id)
            if isRequestedPresentation {
                requestedPresentationId = nil
            }
            logWarning("Stopped retrying incoming Paykit payment request after \(attempt + 1) presentation attempts")
            schedulePresentationRetry()
            return
        }
        let delay = Self.presentationRetryDelays[attempt]
        presentationRetryDates[request.id] = now().addingTimeInterval(delay)
        schedulePresentationRetry()
    }

    func markPresentedIfPending(_ request: PaykitPaymentRequest) -> Bool {
        discardExpiredRequests()
        guard pendingRequests.contains(where: { $0.id == request.id }) else { return false }
        presentedRequestIds.insert(request.id)
        if requestedPresentationId == request.id {
            presentationGeneration += 1
            requestedPresentationId = nil
        }
        presentationRetryAttempts.removeValue(forKey: request.id)
        presentationRetryDates.removeValue(forKey: request.id)
        schedulePresentationRetry()
        persistPresentedRequestIds()
        return true
    }

    private func performRefresh(
        generation: Int,
        excludingProtectedRequestId: PaykitPaymentRequest.ID?
    ) async {
        do {
            let snapshot = try await service.synchronize()
            guard generation == refreshGeneration else { return }
            let protectedRequests = pendingRequests.filter {
                processingRequestIds.contains($0.id) && $0.id != excludingProtectedRequestId
            }
            pendingRequests = snapshot.incoming
            for request in protectedRequests where !pendingRequests.contains(where: { $0.id == request.id }) {
                pendingRequests.append(request)
            }
            historyRequests = snapshot.history.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            let requestIds = Set(pendingRequests.map(\.id))
            presentedRequestIds.formIntersection(requestIds)
            presentationRetryAttempts = presentationRetryAttempts.filter { requestIds.contains($0.key) }
            presentationRetryDates = presentationRetryDates.filter { requestIds.contains($0.key) }
            if requestedPresentationId.map({ !requestIds.contains($0) }) == true {
                presentationGeneration += 1
                requestedPresentationId = nil
            }
            persistPresentedRequestIds()
            discardExpiredRequests()
            schedulePresentationRetry()
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
        resultingState: Paykit.PaymentRequestLifecycleState,
        markApprovedForPayment: Bool = false,
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
            if markApprovedForPayment {
                approvedPaymentRequestIds.insert(request.id)
            }
            let updatedRequest = request.updatingLifecycleState(resultingState)
            historyRequests.removeAll { $0.id == request.id }
            historyRequests.insert(updatedRequest, at: 0)
            pendingRequests.removeAll { $0.id == request.id }
            presentedRequestIds.remove(request.id)
            presentationRetryAttempts.removeValue(forKey: request.id)
            presentationRetryDates.removeValue(forKey: request.id)
            schedulePresentationRetry()
            if requestedPresentationId == request.id {
                presentationGeneration += 1
                requestedPresentationId = nil
            }
            persistPresentedRequestIds()
            discardExpiredRequests()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard actionGeneration == stateGeneration else { throw error }
            invalidateRefresh()
            await refresh(excludingProtectedRequestId: request.id)
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
        if requestedPresentationId.map({ !requestIds.contains($0) }) == true {
            presentationGeneration += 1
            requestedPresentationId = nil
        }
        persistPresentedRequestIds()
        scheduleExpiration()
        schedulePresentationRetry()
    }

    private func schedulePresentationRetry() {
        presentationRetryTask?.cancel()
        presentationRetryTask = nil

        guard let nextRetry = presentationRetryDates.values.min() else { return }
        let delay = max(0, nextRetry.timeIntervalSince(now()))
        presentationRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.presentationRetryTask = nil
            self?.presentationRetryTrigger += 1
        }
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

    private func persistPresentedRequestIds() {
        guard let activeIdentity, presentedRequestIds != persistedPresentedRequestIds else { return }
        do {
            try presentationStore.save(presentedRequestIds, identity: activeIdentity)
            persistedPresentedRequestIds = presentedRequestIds
        } catch {
            logWarning("Failed to persist surfaced Paykit payment requests: \(error)")
        }
    }
}
