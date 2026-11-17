import BitkitCore
import Combine
import CryptoKit
import Foundation
import LDKNode
import Observation
import Paykit

/// How far the receipt for a received payment got: issued and queued, delivered to the payer, or stopped.
enum PaykitReceiptStatus: Equatable {
    case sending
    case sent
    case failed

    /// The status a payment shows when it carries several receipts: any failure, else any still sending.
    static func combined(_ first: Self?, _ second: Self) -> Self {
        guard let first else { return second }
        if first == .failed || second == .failed {
            return .failed
        }
        return first == .sending || second == .sending ? .sending : .sent
    }
}

enum PaykitReceiptRail: Equatable {
    case lightning
    case onchain
    case usdt
}

/// A payment this wallet recorded as received, which a receipt can name.
struct PaykitRecordedReceive: Equatable {
    /// Lowercase payment hash for Lightning, transaction id for on-chain, verified transfer id for USDT.
    let paymentId: String
    let rail: PaykitReceiptRail
    var amount: PaykitAmount
    /// The receiving address of an on-chain receive.
    var address: String?
    /// Sats an on-chain receive paid to each of this wallet's addresses, keyed lowercase; nil when unknown.
    var outputs: [String: UInt64]?
    /// The addresses whose outputs this receive counts toward a request, once narrowed; empty for other rails.
    var countedAddresses: Set<String> = []
    /// What the activity row and received sheet know the payment by: its hash, txid or USDT transfer id.
    var statusKey: String
    /// When the wallet recorded the receive, in seconds since the epoch.
    var receivedAt: UInt64?
    /// The contact the wallet attributed the receive to.
    var contact: String?
    /// The transaction that carried the payment, for the receipt's metadata.
    var transactionId: String

    init(
        paymentId: String,
        rail: PaykitReceiptRail,
        amount: PaykitAmount,
        address: String? = nil,
        statusKey: String? = nil,
        receivedAt: UInt64? = nil,
        contact: String? = nil,
        transactionId: String? = nil
    ) {
        self.paymentId = paymentId.lowercased()
        self.transactionId = (transactionId ?? paymentId).lowercased()
        self.rail = rail
        self.amount = amount
        self.address = address
        self.statusKey = (statusKey ?? paymentId).lowercased()
        self.receivedAt = receivedAt
        self.contact = contact
    }

    /// An on-chain receive narrowed to what it paid to `addresses`, so a batch paying other addresses of this wallet
    /// does not count toward the request; nil when that amount is unknown or zero. Other rails come back unchanged.
    func paid(to addresses: [String]) -> Self? {
        guard rail == .onchain else { return self }
        guard let outputs else { return nil }
        let counted = Set(addresses.map { $0.lowercased() }).filter { (outputs[$0] ?? 0) > 0 }
        guard !counted.isEmpty else { return nil }
        var narrowed = self
        narrowed.amount = PaykitAmount(asset: .btc, atomic: counted.reduce(UInt64(0)) { $0 + (outputs[$1] ?? 0) })
        narrowed.countedAddresses = counted
        return narrowed
    }

    static func bitcoin(
        _ paymentId: String,
        rail: PaykitReceiptRail,
        sats: UInt64,
        address: String? = nil,
        receivedAt: UInt64? = nil,
        contact: String? = nil,
        outputs: [String: UInt64]? = nil
    ) -> Self {
        var receive = Self(
            paymentId: paymentId, rail: rail, amount: PaykitAmount(asset: .btc, atomic: sats), address: address,
            receivedAt: receivedAt, contact: contact
        )
        receive.outputs = outputs
        return receive
    }
}

/// A USDT payment the payee verified on chain for one of its requests.
struct PaykitVerifiedUsdtReceive: Equatable {
    let requestId: PaykitPaymentRequest.ID
    let proofEventId: String
    let transferId: String
    let amount: PaykitAmount
}

/// A request the wallet issued that a recorded receive paid, ready to receipt.
struct PaykitReceiptCandidate {
    let counterparty: String
    let paymentRequestId: String
    let paymentReference: String
    let billingPeriod: Paykit.BillingPeriod?
    let paymentEndpointIdentifier: String
    let receive: PaykitRecordedReceive

    /// Stable across launches, so a catch-up or retry finds the receipt it issued before.
    var receiptId: String {
        PaykitReceiptMatcher.receiptId(
            counterparty: counterparty, paymentRequestId: paymentRequestId,
            billingPeriodStartsAt: billingPeriod?.startsAt, paymentId: receive.paymentId
        )
    }

    /// The paid payment's hash or transaction id, for the Market to match.
    var metadataJson: String {
        switch receive.rail {
        case .lightning: "{\"payment_hash\":\"\(receive.paymentId)\"}"
        case .onchain, .usdt: "{\"txid\":\"\(receive.transactionId)\"}"
        }
    }

    func draft() throws -> Paykit.ReceiptDraft {
        try Paykit.ReceiptDraft(
            receiptId: receiptId,
            paymentReference: Paykit.PaymentReference(text: paymentReference),
            paymentRequestId: paymentRequestId,
            billingPeriod: billingPeriod,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            amount: Paykit.ReceiptAmount(value: receive.amount.value, asset: receive.amount.asset.rawValue),
            metadata: Paykit.PrivateJsonObject(text: metadataJson)
        )
    }
}

/// Pairs the requests this wallet issued with the payments it recorded for them: the payer's proof names the request
/// and the payment, or the request's own invoice or address received it. A proof alone is only the payer's claim, so
/// nothing is receipted until the money is recorded here, after the request was proposed and, when the wallet knows
/// the payer, from that counterparty. A txid is public, so an on-chain proof counts only for a receive the wallet
/// attributed to that counterparty. A payment two requests still claim is left alone.
enum PaykitReceiptMatcher {
    static func candidates(
        records: [Paykit.PaymentRequestRecord],
        lightningReceives: [String: PaykitRecordedReceive],
        onchainReceives: [PaykitRecordedReceive],
        usdtReceives: [PaykitVerifiedUsdtReceive],
        network: LDKNode.Network = Env.network
    ) -> [PaykitReceiptCandidate] {
        let onchainByTxid = Dictionary(onchainReceives.map { ($0.paymentId, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [PaykitReceiptCandidate] = []
        for record in records where isReceiptable(record) {
            guard let terms = record.terms else { continue }
            let reference = terms.paymentReference.exportText()
            func candidate(_ endpoint: String, _ period: Paykit.BillingPeriod?, _ receive: PaykitRecordedReceive) -> PaykitReceiptCandidate {
                PaykitReceiptCandidate(
                    counterparty: record.counterparty, paymentRequestId: record.paymentRequestId, paymentReference: reference,
                    billingPeriod: period, paymentEndpointIdentifier: endpoint, receive: receive
                )
            }

            // A proof's payment counts only toward the request's own addresses when it names any, else toward the
            // address the wallet attributed to the payer.
            let requestAddresses = onchainAddresses(terms, network)
            for proof in record.paymentProofs {
                guard let (rail, id) = bitcoinPaymentId(proof),
                      let recorded = rail == .lightning ? lightningReceives[id] : onchainByTxid[id],
                      rail == .lightning || PubkyPublicKeyFormat.matches(recorded.contact, record.counterparty),
                      let receive = recorded.paid(to: requestAddresses.isEmpty ? [recorded.address].compactMap(\.self) : requestAddresses),
                      couldBePaid(record, by: receive)
                else { continue }
                found.append(candidate(proof.paymentEndpointIdentifier, proof.billingPeriod, receive))
            }
            if terms.recurrence == nil {
                for (endpoint, receive) in embeddedEndpointReceives(terms, lightningReceives, onchainReceives, network)
                    where couldBePaid(record, by: receive)
                {
                    found.append(candidate(endpoint, nil, receive))
                }
            }
            for usdt in usdtReceives where usdt.requestId.paymentRequestId == record.paymentRequestId &&
                usdt.requestId.counterparty == record.counterparty
            {
                guard let proof = record.paymentProofs.first(where: { $0.eventId == usdt.proofEventId }),
                      let hash = proofValue(proof, "transaction_hash")
                else { continue }
                let receive = PaykitRecordedReceive(
                    paymentId: usdt.transferId, rail: .usdt, amount: usdt.amount, transactionId: hash
                )
                found.append(candidate(proof.paymentEndpointIdentifier, proof.billingPeriod, receive))
            }
        }
        var seen = Set<String>()
        let unique = found.filter {
            seen.insert([$0.counterparty, $0.paymentRequestId, $0.billingPeriod?.startsAt ?? "", $0.receive.paymentId].joined(separator: "|"))
                .inserted
        }
        // Requests that claim the same payment are left alone; one transaction paying separate outputs to each of
        // several requests receipts each one.
        return Dictionary(grouping: unique, by: \.receive.paymentId).values.flatMap { claims in
            claims.indices.compactMap { index in
                let receive = claims[index].receive
                let overlaps = claims.indices.contains { other in
                    other != index &&
                        (receive.countedAddresses.isEmpty || !receive.countedAddresses.isDisjoint(with: claims[other].receive.countedAddresses))
                }
                return overlaps ? nil : claims[index]
            }
        }
    }

    /// A UUID v4 derived from the receipt's request and payment, as Paykit requires a v4 Receipt ID.
    static func receiptId(counterparty: String, paymentRequestId: String, billingPeriodStartsAt: String?, paymentId: String) -> String {
        let seed = ["bitkit-receipt", counterparty, paymentRequestId, billingPeriodStartsAt ?? "", paymentId].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x40
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    static let receiveTimeTolerance: TimeInterval = 2 * 60 * 60

    private static func couldBePaid(_ record: Paykit.PaymentRequestRecord, by receive: PaykitRecordedReceive) -> Bool {
        if let contact = receive.contact, !PubkyPublicKeyFormat.matches(contact, record.counterparty) {
            return false
        }
        guard let receivedAt = receive.receivedAt, let recordedAt = record.proposalRecordedAt else { return true }
        guard let proposedAt = PaykitPaymentRequest.parseDate(recordedAt) else { return false }
        // Lightning receive and request times both come from this device's clock; only block time can lag.
        let tolerance = receive.rail == .lightning ? 0 : receiveTimeTolerance
        // Receive times are whole seconds, so compare at that precision.
        return TimeInterval(receivedAt) >= (proposedAt.timeIntervalSince1970 - tolerance).rounded(.down)
    }

    private static func isReceiptable(_ record: Paykit.PaymentRequestRecord) -> Bool {
        record.localRole == .payee && record.invalidReason == nil && record.state != .invalidConflict && record.state != .unknown
    }

    private static func embeddedEndpointReceives(
        _ terms: Paykit.PaymentRequestTerms,
        _ lightningReceives: [String: PaykitRecordedReceive],
        _ onchainReceives: [PaykitRecordedReceive],
        _ network: LDKNode.Network
    ) -> [(String, PaykitRecordedReceive)] {
        var matches: [(String, PaykitRecordedReceive)] = []
        for (identifier, data) in terms.paymentEndpoints ?? [:] {
            guard terms.acceptedPaymentEndpointIdentifiers.contains(identifier),
                  let method = PublicPaykitService.MethodId(rawValue: identifier),
                  let payload = PaykitIssuerInterop.parseEndpointPayload(data)
            else { continue }
            if method == .bitcoinLightningBolt11,
               let hash = try? Bolt11Invoice.fromStr(invoiceStr: payload.value).paymentHash().lowercased(),
               let receive = lightningReceives[hash]
            {
                matches.append((identifier, receive))
            }
        }
        // One receive counts once toward the request, over every on-chain address it names, so a transaction paying
        // two of them is receipted in full. A batch can pay them while the activity shows another address.
        let endpoints = onchainEndpoints(terms, network)
        for receive in onchainReceives {
            guard let paid = receive.paid(to: endpoints.map(\.address)),
                  let endpoint = endpoints.first(where: { paid.countedAddresses.contains($0.address.lowercased()) })
            else { continue }
            matches.append((endpoint.identifier, paid))
        }
        return matches
    }

    private static func onchainAddresses(_ terms: Paykit.PaymentRequestTerms, _ network: LDKNode.Network) -> [String] {
        onchainEndpoints(terms, network).map(\.address)
    }

    private static func onchainEndpoints(
        _ terms: Paykit.PaymentRequestTerms,
        _ network: LDKNode.Network
    ) -> [(identifier: String, address: String)] {
        (terms.paymentEndpoints ?? [:]).compactMap { identifier, data -> (identifier: String, address: String)? in
            guard terms.acceptedPaymentEndpointIdentifiers.contains(identifier),
                  let method = PublicPaykitService.MethodId(rawValue: identifier), method.onchainNetwork == network,
                  let payload = PaykitIssuerInterop.parseEndpointPayload(data)
            else { return nil }
            return (identifier, payload.value)
        }.sorted { $0.identifier < $1.identifier }
    }

    private static func proofValue(_ proof: Paykit.PaymentProofRecord, _ key: String) -> String? {
        let text = proof.proof.exportText()
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    private static func bitcoinPaymentId(_ proof: Paykit.PaymentProofRecord) -> (PaykitReceiptRail, String)? {
        if let txid = proofValue(proof, "txid")?.lowercased(), txid.count == 64, txid.hexaData.count == 32 {
            return (.onchain, txid)
        }
        guard let data = proofValue(proof, "data")?.lowercased(), data.count == 64 else { return nil }
        let bytes = data.hexaData
        guard bytes.count == 32 else { return nil }
        switch proofValue(proof, "type") {
        case PaykitPaymentProofKind.lightning.rawValue: return (.lightning, Data(SHA256.hash(data: bytes)).hex)
        case PaykitPaymentProofKind.onchain.rawValue: return (.onchain, data)
        default: return nil
        }
    }
}

/// Issues a Paykit receipt for each request this wallet issued once its payment is recorded here, on any rail, and
/// sends Receipt Access to the payer. It scans what is recorded, so a payment received while the app was closed gets
/// its receipt on the next open; a receipt that failed is tried again once per launch and on retry.
@Observable @MainActor
final class PaykitReceiptService {
    static let shared = PaykitReceiptService()

    /// Receipt status by the payment's hash, txid or USDT transfer id, lowercase.
    private(set) var statuses: [String: PaykitReceiptStatus] = [:]

    @ObservationIgnored private let sdk: PaykitReceiptSdk
    @ObservationIgnored private let delivery: PaykitOutboundDeliveryLog
    @ObservationIgnored private let activities: () async throws -> [Activity]
    @ObservationIgnored private let usdtReceipts: @MainActor () -> [PaykitUsdtPaymentService.Receipt]
    @ObservationIgnored private let transactionOutputs: (String) async -> [String: UInt64]?
    /// Confirmed transactions do not change, so their outputs are read once per launch.
    @ObservationIgnored private var outputsByTxid: [String: [String: UInt64]] = [:]
    @ObservationIgnored private var attemptedReceiptIds = Set<String>()
    @ObservationIgnored private var candidates: [String: [PaykitReceiptCandidate]] = [:]
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var running: Task<Void, Never>?

    init(
        sdk: PaykitReceiptSdk = PaykitSdkService.shared,
        delivery: PaykitOutboundDeliveryLog = .shared,
        activities: @escaping () async throws -> [Activity] = { try await CoreService.shared.activity.get(txType: .received) },
        usdtReceipts: @escaping @MainActor () -> [PaykitUsdtPaymentService.Receipt] = { PaykitUsdtPaymentService.shared.receipts },
        transactionOutputs: @escaping (String) async -> [String: UInt64]? = PaykitReceiptService.storedOutputs
    ) {
        self.sdk = sdk
        self.delivery = delivery
        self.activities = activities
        self.usdtReceipts = usdtReceipts
        self.transactionOutputs = transactionOutputs
    }

    /// Sats a stored transaction paid to each address, keyed lowercase; nil when its details are not stored.
    private static func storedOutputs(txid: String) async -> [String: UInt64]? {
        guard let details = try? await CoreService.shared.activity.getTransactionDetails(txid: txid) else { return nil }
        return details.outputs.reduce(into: [:]) { outputs, output in
            guard let address = output.scriptpubkeyAddress?.lowercased(), output.value > 0 else { return }
            outputs[address, default: 0] += UInt64(output.value)
        }
    }

    func reconcile() async {
        await serialized { await self.reconcileNow() }
    }

    func retry(paymentId: String) async {
        await serialized {
            let key = paymentId.lowercased()
            guard let receipts = self.candidates[key], let identity = self.identity else { return }
            self.statuses[key] = .sending
            for candidate in receipts {
                await self.issue(candidate, identity: identity)
            }
            if await !self.publish(self.candidates.values.flatMap(\.self), identity: identity) {
                self.statuses[key] = .failed
            }
        }
    }

    func reset() {
        attemptedReceiptIds = []
        outputsByTxid = [:]
        candidates = [:]
        identity = nil
        statuses = [:]
    }

    private func serialized(_ work: @escaping @MainActor () async -> Void) async {
        let previous = running
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        running = task
        await task.value
    }

    private func reconcileNow() async {
        do {
            guard let status = try await sdk.identityStatus(priority: .background),
                  status.capability == .privateLinkCapable, let current = status.publicKey
            else {
                reset()
                return
            }
            if !PubkyPublicKeyFormat.matches(identity, current) {
                reset()
            }
            identity = current

            let records = try await sdk.sharedPaymentRequests(priority: .background).filter { $0.localRole == .payee }
            let hasPayments = records.contains { !$0.paymentProofs.isEmpty || !($0.terms?.paymentEndpoints ?? [:]).isEmpty }
            let found: [PaykitReceiptCandidate]
            if hasPayments {
                let received = try await activities()
                found = await PaykitReceiptMatcher.candidates(
                    records: records,
                    lightningReceives: Self.lightningReceives(received),
                    onchainReceives: onchainReceives(received, records: records),
                    usdtReceives: usdtReceives(identity: current)
                )
            } else {
                found = []
            }
            candidates = Dictionary(grouping: found, by: \.receive.statusKey)
            guard !found.isEmpty else {
                statuses = [:]
                return
            }

            let issued = try await issuedViews()
            for candidate in found {
                if issued[candidate.receiptId]?.status == .accessQueued || attemptedReceiptIds.contains(candidate.receiptId) {
                    continue
                }
                await issue(candidate, identity: current)
                attemptedReceiptIds.insert(candidate.receiptId)
            }
            await publish(found, identity: current)
        } catch {
            Logger.warn("Failed to reconcile Paykit receipts: \(error)", context: "PaykitReceiptService")
        }
    }

    private func issue(_ candidate: PaykitReceiptCandidate, identity: String) async {
        do {
            let view = try await sdk.issueReceipt(
                counterparty: candidate.counterparty, draft: candidate.draft(), expectedIdentity: identity, priority: .background
            )
            Logger.info("Issued Paykit receipt '\(candidate.receiptId)' with status '\(view.status)'", context: "PaykitReceiptService")
        } catch {
            Logger.warn("Failed to issue Paykit receipt '\(candidate.receiptId)': \(error)", context: "PaykitReceiptService")
        }
    }

    /// Returns false when it could not read the issued receipts and left the statuses as they were.
    @discardableResult
    private func publish(_ found: [PaykitReceiptCandidate], identity: String) async -> Bool {
        guard var views = await readIssuedViews() else { return false }
        let undelivered = found.filter { deliveryOf($0, views, identity: identity) != true }
        var unreachable: [String] = []
        if !undelivered.isEmpty {
            unreachable = await drain(undelivered, views: views, identity: identity)
            guard let drained = await readIssuedViews() else { return false }
            views = drained
        }
        var updated: [String: PaykitReceiptStatus] = [:]
        for candidate in found {
            let sent = deliveryOf(candidate, views, identity: identity)
            let status: PaykitReceiptStatus = if sent == true {
                .sent
            } else if views[candidate.receiptId]?.status != .accessQueued || sent == false {
                .failed
            } else if unreachable.contains(where: { PubkyPublicKeyFormat.matches($0, candidate.counterparty) }) {
                .failed
            } else {
                .sending
            }
            updated[candidate.receive.statusKey] = .combined(updated[candidate.receive.statusKey], status)
        }
        statuses = updated
        return true
    }

    private func deliveryOf(
        _ candidate: PaykitReceiptCandidate,
        _ views: [String: Paykit.ReceiptIssuanceView],
        identity: String
    ) -> Bool? {
        delivery.deliveryOf(identity: identity, receiptId: candidate.receiptId, messageId: views[candidate.receiptId]?.outboundMessageId)
    }

    /// Drains each counterparty's queue and marks its receipts sent right after, before a later drain can prune the
    /// evidence. Returns the counterparties that could not be reached.
    private func drain(_ found: [PaykitReceiptCandidate], views: [String: Paykit.ReceiptIssuanceView], identity: String) async -> [String] {
        var counterparties: [String] = []
        for candidate in found where !counterparties.contains(where: { PubkyPublicKeyFormat.matches($0, candidate.counterparty) }) {
            counterparties.append(candidate.counterparty)
        }
        var unreachable: [String] = []
        for counterparty in counterparties {
            do {
                let report = try await sdk.processOutboundPrivateMessages(
                    counterparty: counterparty, priority: .background, expectedIdentity: identity
                )
                delivery.record(identity: identity, report: report)
            } catch {
                Logger.warn("Failed to send Paykit receipt access: \(error)", context: "PaykitReceiptService")
                unreachable.append(counterparty)
            }
            for candidate in found where PubkyPublicKeyFormat.matches(candidate.counterparty, counterparty) {
                _ = deliveryOf(candidate, views, identity: identity)
            }
        }
        return unreachable
    }

    private func readIssuedViews() async -> [String: Paykit.ReceiptIssuanceView]? {
        do {
            return try await issuedViews()
        } catch {
            Logger.warn("Failed to read issued Paykit receipts: \(error)", context: "PaykitReceiptService")
            return nil
        }
    }

    private func issuedViews() async throws -> [String: Paykit.ReceiptIssuanceView] {
        try await Dictionary(sdk.issuedReceipts(priority: .background).map { ($0.receiptId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func usdtReceives(identity: String) -> [PaykitVerifiedUsdtReceive] {
        usdtReceipts()
            .filter { $0.verified && $0.beforeRequest != true && PubkyPublicKeyFormat.matches($0.identity, identity) }
            .map { PaykitVerifiedUsdtReceive(requestId: $0.requestId, proofEventId: $0.proofEventId, transferId: $0.transferId, amount: $0.amount) }
    }

    private static func lightningReceives(_ activities: [Activity]) -> [String: PaykitRecordedReceive] {
        var receives: [String: PaykitRecordedReceive] = [:]
        for case let .lightning(activity) in activities where activity.txType == .received && activity.status == .succeeded {
            let receive = PaykitRecordedReceive.bitcoin(
                activity.id, rail: .lightning, sats: activity.value, receivedAt: activity.timestamp, contact: activity.contact
            )
            receives[receive.paymentId] = receive
        }
        return receives
    }

    /// Confirmed on-chain receives with their outputs, so a receipt counts only what was paid to the request. Outputs
    /// are read for each receive a proof names, and for every receive since the earliest request with an on-chain
    /// address was proposed, since a batch can pay that address while the activity shows another one.
    private func onchainReceives(_ activities: [Activity], records: [Paykit.PaymentRequestRecord]) async -> [PaykitRecordedReceive] {
        let mentions = records.flatMap { $0.paymentProofs.map { $0.proof.exportText().lowercased() } }
        let endpointsSince = records.filter { record in
            (record.terms?.paymentEndpoints ?? [:]).keys.contains { PublicPaykitService.MethodId(rawValue: $0)?.onchainNetwork != nil }
        }.map { record in
            (record.proposalRecordedAt.flatMap(PaykitPaymentRequest.parseDate) ?? .distantPast)
                .addingTimeInterval(-PaykitReceiptMatcher.receiveTimeTolerance)
        }.min()
        var receives: [PaykitRecordedReceive] = []
        for case let .onchain(activity) in activities where activity.txType == .received && activity.confirmed && activity.doesExist {
            let txid = activity.txId.lowercased()
            let address = activity.address.lowercased()
            var outputs: [String: UInt64]?
            let afterEndpoint = endpointsSince.map { Date(timeIntervalSince1970: TimeInterval(activity.timestamp)) >= $0 } ?? false
            if afterEndpoint || mentions.contains(where: { $0.contains(txid) || (!address.isEmpty && $0.contains(address)) }) {
                outputs = outputsByTxid[txid]
                if outputs == nil, let read = await transactionOutputs(txid) {
                    outputsByTxid[txid] = read
                    outputs = read
                }
            }
            receives.append(.bitcoin(
                activity.txId, rail: .onchain, sats: activity.value, address: activity.address,
                receivedAt: activity.timestamp, contact: activity.contact, outputs: outputs
            ))
        }
        return receives
    }
}

/// The Paykit calls receipts need, so tests can stand in for the SDK.
protocol PaykitReceiptSdk: Sendable {
    func identityStatus(priority: PaykitSdkOperationLock.Priority) async throws -> Paykit.IdentityStatus?
    func sharedPaymentRequests(priority: PaykitSdkOperationLock.Priority) async throws -> [Paykit.PaymentRequestRecord]
    func issueReceipt(
        counterparty: String,
        draft: Paykit.ReceiptDraft,
        expectedIdentity: String,
        priority: PaykitSdkOperationLock.Priority
    ) async throws -> Paykit.ReceiptIssuanceView
    func issuedReceipts(priority: PaykitSdkOperationLock.Priority) async throws -> [Paykit.ReceiptIssuanceView]
    func processOutboundPrivateMessages(
        counterparty: String,
        priority: PaykitSdkOperationLock.Priority,
        expectedIdentity: String?
    ) async throws -> Paykit.OutboundPrivateSendReport
}

extension PaykitSdkService: PaykitReceiptSdk {}

/// What drains reported for queued Paykit private messages, kept across launches and per identity: the SDK reports a
/// message's delivery only to the call that drained it, so a receipt counts as sent only once some drain saw its message
/// go out. Message ids are local to one identity's Paykit state, so each identity keeps its own records.
final class PaykitOutboundDeliveryLog: @unchecked Sendable {
    static let shared = PaykitOutboundDeliveryLog()

    /// Most message outcomes kept per identity besides the latest report's; the oldest ids are dropped first.
    private static let maxEntries = 1000
    private static let backupChanged = PassthroughSubject<Void, Never>()
    /// Fires when a receipt is first seen sent, the only part of these records the wallet backup keeps.
    static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        backupChanged.eraseToAnyPublisher()
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "paykitOutboundDelivery") {
        self.defaults = defaults
        self.key = key
    }

    func record(identity: String, report: Paykit.OutboundPrivateSendReport) {
        guard !report.sent.isEmpty || !report.failed.isEmpty else { return }
        var reported: [String: Bool] = [:]
        report.failed.forEach { reported[String($0.outboundMessageId)] = false }
        report.sent.forEach { reported[String($0)] = true }
        update(identity: identity) { records in
            let older = records.outcomes.filter { reported[$0.key] == nil }
            let kept = Set(older.keys.compactMap(UInt64.init).sorted().suffix(Self.maxEntries).map(String.init))
            records.outcomes = older.filter { kept.contains($0.key) }.merging(reported) { _, new in new }
        }
    }

    /// True once the receipt or its access message was seen sent, false when the message's latest drain failed, nil
    /// when no drain reported it. A sent message marks the receipt sent in the same write, so it stays sent whatever
    /// later pruning drops, and a reset that lands first leaves nothing to restore.
    func deliveryOf(identity: String, receiptId: String, messageId: UInt64?) -> Bool? {
        var delivery: Bool?
        update(identity: identity) { records in
            if records.sentReceiptIds.contains(receiptId) {
                delivery = true
                return
            }
            delivery = messageId.flatMap { records.outcomes[String($0)] }
            if delivery == true {
                records.sentReceiptIds.append(receiptId)
            }
        }
        return delivery
    }

    func reset() {
        lock.withLock { defaults.removeObject(forKey: key) }
    }

    /// Receipt ids seen sent, by identity, for the wallet backup: a restored SDK does not drain a sent message again,
    /// so only these records show the receipt as sent. Nil when none were.
    func backupSnapshot() -> [String: [String]]? {
        let all = lock.withLock { defaults.dictionary(forKey: key) ?? [:] }
        let sent = all.compactMapValues { (($0 as? [String: Any])?["sentReceiptIds"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } }
        return sent.isEmpty ? nil : sent
    }

    /// Adds the restored sent receipt ids to what this device already recorded.
    func restoreBackup(_ sentReceiptIds: [String: [String]]) {
        for (identity, ids) in sentReceiptIds {
            update(identity: identity) { records in
                records.sentReceiptIds += ids.filter { !records.sentReceiptIds.contains($0) }
            }
        }
    }

    private struct Records: Equatable {
        var outcomes: [String: Bool] = [:]
        var sentReceiptIds: [String] = []
    }

    private func update(identity: String, _ change: (inout Records) -> Void) {
        let sentChanged = lock.withLock {
            let current = records(identity: identity)
            var records = current
            change(&records)
            guard records != current else { return false }
            var all = defaults.dictionary(forKey: key) ?? [:]
            all[storageKey(identity)] = ["outcomes": records.outcomes, "sentReceiptIds": records.sentReceiptIds]
            defaults.set(all, forKey: key)
            return records.sentReceiptIds != current.sentReceiptIds
        }
        if sentChanged {
            Self.backupChanged.send()
        }
    }

    private func records(identity: String) -> Records {
        let value = defaults.dictionary(forKey: key)?[storageKey(identity)] as? [String: Any]
        return Records(
            outcomes: value?["outcomes"] as? [String: Bool] ?? [:],
            sentReceiptIds: value?["sentReceiptIds"] as? [String] ?? []
        )
    }

    private func storageKey(_ identity: String) -> String {
        PubkyPublicKeyFormat.normalized(identity) ?? identity
    }
}
