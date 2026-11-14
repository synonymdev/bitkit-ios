@testable import Bitkit
import BitkitCore
import CryptoKit
import Paykit
import XCTest

@MainActor
final class PaykitReceiptServiceTests: XCTestCase {
    private nonisolated static let buyer = "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o"
    private static let otherBuyer = "pubkya3mduedw686dysw8ndr5c1dyry5h8k6i8hzbbmx9gf9k43zq4s9o"
    private static let seller = "pubkyc3mduedw686dysw8ndr5c1dyry5h8k6i8hzbbmx9gf9k43zq4s9o"
    private static let address = "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"
    private static let onchainMethod = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
    private static let bolt11Method = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
    private nonisolated static let requestId = "4f1c2a3b-1d2e-4f5a-8b6c-7d8e9f0a1b2c"
    private static let preimage = String(repeating: "11", count: 32)
    private static let hash = Data(SHA256.hash(data: Data(repeating: 0x11, count: 32))).hex
    private static let txid = String(repeating: "cd", count: 32)

    // MARK: - Matcher

    func testLightningProofWithRecordedReceiveReceiptsWhatArrived() throws {
        let request = try payeeRequest(proofs: [proof(type: "bitcoin-bolt11-preimage", data: Self.preimage, endpoint: Self.bolt11Method)])
        let partial = PaykitRecordedReceive.bitcoin(Self.hash, rail: .lightning, sats: 1000)

        let candidates = match([request], lightning: [partial])

        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.paymentRequestId, Self.requestId)
        XCTAssertEqual(candidate.paymentReference, "order-42")
        XCTAssertEqual(candidate.paymentEndpointIdentifier, Self.bolt11Method)
        XCTAssertEqual(candidate.receive.amount.value, "0.00001")
        XCTAssertEqual(candidate.metadataJson, "{\"payment_hash\":\"\(Self.hash)\"}")
    }

    func testProofWithoutRecordedReceiveIssuesNothing() throws {
        let request = try payeeRequest(proofs: [proof(type: "bitcoin-bolt11-preimage", data: Self.preimage, endpoint: Self.bolt11Method)])

        XCTAssertTrue(match([request]).isEmpty)
    }

    func testBareTxidProofFromAnotherPaykitAppIsMatchedToTheRecordedReceive() throws {
        let request = try payeeRequest(proofs: [proof(json: "{\"txid\":\"\(Self.txid)\"}", endpoint: Self.onchainMethod, eventId: "event-1")])

        let candidates = match([request], onchain: [.bitcoin(Self.txid, rail: .onchain, sats: 10000)])

        XCTAssertEqual(candidates.map(\.metadataJson), ["{\"txid\":\"\(Self.txid)\"}"])
    }

    func testRequestsTheWalletPaysAreNeverReceipted() throws {
        let request = try payeeRequest(
            role: .payer,
            proofs: [proof(type: "bitcoin-onchain-txid", data: Self.txid, endpoint: Self.onchainMethod)]
        )

        XCTAssertTrue(match([request], onchain: [.bitcoin(Self.txid, rail: .onchain, sats: 15000)]).isEmpty)
    }

    func testMarketRequestReceiptsAnOverpaymentToItsOwnAddressWithoutAProof() throws {
        let request = try payeeRequest(endpoints: [Self.onchainMethod: "{\"value\":\"\(Self.address)\"}"])
        let overpaid = PaykitRecordedReceive.bitcoin(Self.txid, rail: .onchain, sats: 20000, address: Self.address)

        let candidate = try XCTUnwrap(match([request], onchain: [overpaid]).first)

        XCTAssertEqual(candidate.paymentEndpointIdentifier, Self.onchainMethod)
        XCTAssertEqual(candidate.receive.amount.value, "0.0002")
        XCTAssertEqual(candidate.metadataJson, "{\"txid\":\"\(Self.txid)\"}")
    }

    func testPaymentTwoRequestsClaimIsLeftAlone() throws {
        let claim = try proof(type: "bitcoin-onchain-txid", data: Self.txid, endpoint: Self.onchainMethod)
        let first = try payeeRequest(proofs: [claim])
        let second = try payeeRequest(counterparty: Self.otherBuyer, requestId: "5f1c2a3b-1d2e-4f5a-8b6c-7d8e9f0a1b2c", proofs: [claim])

        XCTAssertTrue(match([first, second], onchain: [.bitcoin(Self.txid, rail: .onchain, sats: 1)]).isEmpty)
    }

    func testReceiveRecordedWellBeforeTheRequestWasProposedIsNotReceipted() throws {
        let request = try payeeRequest(
            proofs: [proof(type: "bitcoin-onchain-txid", data: Self.txid, endpoint: Self.onchainMethod)],
            proposedAt: "2026-11-14T12:00:00.123456789+00:00"
        )
        let unreadable = try payeeRequest(
            proofs: [proof(type: "bitcoin-onchain-txid", data: Self.txid, endpoint: Self.onchainMethod)],
            proposedAt: "yesterday"
        )
        let earlier = PaykitRecordedReceive.bitcoin(Self.txid, rail: .onchain, sats: 1000, receivedAt: 1_763_100_000)
        let later = PaykitRecordedReceive.bitcoin(Self.txid, rail: .onchain, sats: 1000, receivedAt: 1_794_657_600)

        XCTAssertTrue(match([request], onchain: [earlier]).isEmpty)
        XCTAssertEqual(match([request], onchain: [later]).count, 1)
        XCTAssertTrue(match([unreadable], onchain: [later]).isEmpty)
    }

    func testClaimOnAPaymentTheWalletAttributesToAnotherContactIsIgnored() throws {
        let claim = try proof(type: "bitcoin-onchain-txid", data: Self.txid, endpoint: Self.onchainMethod)
        let payer = try payeeRequest(proofs: [claim])
        let claimant = try payeeRequest(counterparty: Self.otherBuyer, requestId: "5f1c2a3b-1d2e-4f5a-8b6c-7d8e9f0a1b2c", proofs: [claim])
        let receive = PaykitRecordedReceive.bitcoin(Self.txid, rail: .onchain, sats: 1000, contact: Self.buyer)

        let candidates = match([payer, claimant], onchain: [receive])

        XCTAssertEqual(candidates.map(\.counterparty), [Self.buyer])
    }

    func testUsdtReceiptNamesTheProofTransactionAndKeysStatusByTransfer() throws {
        let usdtProof = try proof(
            json: "{\"type\":\"erc20-transfer-eip712\",\"transaction_hash\":\"0xABC\"}",
            endpoint: PublicPaykitService.MethodId.usdtArbitrum.rawValue,
            eventId: "usdt-event"
        )
        let request = try payeeRequest(proofs: [usdtProof])
        let usdt = PaykitVerifiedUsdtReceive(
            requestId: PaykitPaymentRequest.ID(paymentRequestId: Self.requestId, counterparty: Self.buyer),
            proofEventId: "usdt-event",
            transferId: "Transfer-1",
            amount: PaykitAmount(asset: .usdt, atomic: 9_000_000)
        )

        let candidate = try XCTUnwrap(match([request], usdt: [usdt]).first)

        XCTAssertEqual(candidate.receive.paymentId, "0xabc")
        XCTAssertEqual(candidate.receive.statusKey, "transfer-1")
        XCTAssertEqual(candidate.receive.amount.value, "9")
        XCTAssertEqual(candidate.metadataJson, "{\"txid\":\"0xabc\"}")
    }

    func testReceiptIdIsAStableUuidV4PerRequestAndPayment() throws {
        let id = PaykitReceiptMatcher.receiptId(
            counterparty: Self.buyer, paymentRequestId: Self.requestId, billingPeriodStartsAt: nil, paymentId: Self.hash
        )
        let other = PaykitReceiptMatcher.receiptId(
            counterparty: Self.buyer, paymentRequestId: Self.requestId, billingPeriodStartsAt: nil, paymentId: Self.txid
        )

        XCTAssertEqual(id, PaykitReceiptMatcher.receiptId(
            counterparty: Self.buyer, paymentRequestId: Self.requestId, billingPeriodStartsAt: nil, paymentId: Self.hash
        ))
        XCTAssertNotEqual(id, other)
        let uuid = try XCTUnwrap(UUID(uuidString: id))
        XCTAssertEqual(uuid.uuid.6 >> 4, 4)
        XCTAssertEqual(uuid.uuid.8 >> 6, 2)
    }

    // MARK: - Service

    func testPaymentRecordedWhileClosedGetsItsReceiptAndAccessOnTheNextOpen() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        let service = makeService(sdk)

        await service.reconcile()

        XCTAssertEqual(sdk.issuedCount, 1)
        XCTAssertEqual(sdk.drainedCounterparties, [Self.buyer])
        XCTAssertEqual(service.statuses, [Self.hash: .sent])
    }

    func testFailedReceiptWaitsForRetryThenSends() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        sdk.issueFails = true
        let service = makeService(sdk)

        await service.reconcile()
        await service.reconcile()

        XCTAssertEqual(sdk.issuedCount, 1)
        XCTAssertEqual(service.statuses, [Self.hash: .failed])

        sdk.issueFails = false
        await service.retry(paymentId: Self.hash.uppercased())

        XCTAssertEqual(sdk.issuedCount, 2)
        XCTAssertEqual(service.statuses, [Self.hash: .sent])
    }

    func testReceiptQueuedOnAnEarlierLaunchIsNotIssuedAgain() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        await makeService(sdk).reconcile()

        let restarted = makeService(sdk)
        await restarted.reconcile()

        XCTAssertEqual(sdk.issuedCount, 1)
        XCTAssertEqual(restarted.statuses, [Self.hash: .sent])
    }

    func testReceiptStaysSendingUntilADrainReportsItsMessageSent() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        sdk.drainOutcome = .none
        let service = makeService(sdk)

        await service.reconcile()

        XCTAssertEqual(service.statuses, [Self.hash: .sending])
    }

    func testReceiptFailsWhenItsMessageFailsToSend() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        sdk.drainOutcome = .failed
        let service = makeService(sdk)

        await service.reconcile()

        XCTAssertEqual(service.statuses, [Self.hash: .failed])
    }

    func testReceiptFailsWhenItsCounterpartyCannotBeReached() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        sdk.drainOutcome = .unreachable
        let service = makeService(sdk)

        await service.reconcile()

        XCTAssertEqual(service.statuses, [Self.hash: .failed])
    }

    func testReceiptSentByAnotherDrainCountsAsSent() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        sdk.drainOutcome = .none
        let service = makeService(sdk)
        await service.reconcile()

        delivery.record(OutboundPrivateSendReport(
            attempted: [7], sent: [7], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: []
        ))
        await service.reconcile()

        XCTAssertEqual(service.statuses, [Self.hash: .sent])
    }

    func testDeliveryOfAnotherIdentityIsForgotten() {
        delivery.bind(identity: Self.seller)
        delivery.record(OutboundPrivateSendReport(
            attempted: [7], sent: [7], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: []
        ))

        delivery.bind(identity: Self.otherBuyer)

        XCTAssertNil(delivery.wasSent(7))
    }

    func testNothingIsIssuedBeforeThePaymentIsRecorded() async throws {
        let sdk = try FakeReceiptSdk(requests: [lightningPaidRequest()])
        let service = makeService(sdk, received: false)

        await service.reconcile()

        XCTAssertEqual(sdk.issuedCount, 0)
        XCTAssertTrue(service.statuses.isEmpty)
    }

    // MARK: - Fixtures

    private var delivery: PaykitOutboundDeliveryLog!

    override func setUp() {
        super.setUp()
        let suite = "PaykitReceiptServiceTests.\(UUID().uuidString)"
        delivery = PaykitOutboundDeliveryLog(defaults: UserDefaults(suiteName: suite)!)
    }

    private func match(
        _ records: [PaymentRequestRecord],
        lightning: [PaykitRecordedReceive] = [],
        onchain: [PaykitRecordedReceive] = [],
        usdt: [PaykitVerifiedUsdtReceive] = []
    ) -> [PaykitReceiptCandidate] {
        PaykitReceiptMatcher.candidates(
            records: records,
            lightningReceives: Dictionary(uniqueKeysWithValues: lightning.map { ($0.paymentId, $0) }),
            onchainReceives: onchain,
            usdtReceives: usdt,
            network: .regtest
        )
    }

    private func makeService(_ sdk: FakeReceiptSdk, received: Bool = true) -> PaykitReceiptService {
        let activity = Activity.lightning(LightningActivity(
            walletId: WalletScope.default, id: Self.hash, txType: .received, status: .succeeded, value: 15000, fee: 0,
            invoice: "invoice", message: "", timestamp: 1, preimage: nil, contact: nil,
            createdAt: nil, updatedAt: nil, seenAt: nil
        ))
        return PaykitReceiptService(sdk: sdk, delivery: delivery, activities: { received ? [activity] : [] }, usdtReceipts: { [] })
    }

    private func lightningPaidRequest() throws -> PaymentRequestRecord {
        try payeeRequest(proofs: [proof(type: "bitcoin-bolt11-preimage", data: Self.preimage, endpoint: Self.bolt11Method)])
    }

    private func proof(type: String, data: String, endpoint: String) throws -> PaymentProofRecord {
        try proof(json: "{\"data\":\"\(data)\",\"type\":\"\(type)\"}", endpoint: endpoint, eventId: "event-1")
    }

    private func proof(json: String, endpoint: String, eventId: String) throws -> PaymentProofRecord {
        try PaymentProofRecord(
            eventId: eventId, outboundMessageId: nil, outboundStatus: nil, streamItemId: 2,
            paymentReference: PaymentReference(text: "order-42"), billingPeriod: nil, paymentAppId: "bitkit",
            paymentEndpointIdentifier: endpoint, allowanceId: nil, conversionQuoteId: nil,
            proof: PrivateJsonObject(text: json), recordedAt: "2027-01-15T08:01:00Z"
        )
    }

    private func payeeRequest(
        counterparty: String = buyer,
        requestId: String = requestId,
        role: PaymentRequestLocalRole = .payee,
        proofs: [PaymentProofRecord] = [],
        endpoints: [String: String]? = nil,
        proposedAt: String? = nil
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty,
            paymentRequestId: requestId,
            localRole: role,
            state: .proofSubmitted,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            proposalAppId: "bitkit",
            proposalRecordedAt: proposedAt,
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.00015", asset: "btc"),
                paymentReference: PaymentReference(text: "order-42"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: [Self.onchainMethod, Self.bolt11Method],
                paymentEndpoints: endpoints,
                requiredAppId: "bitkit",
                conversion: nil,
                paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            acceptanceRecordedAt: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
            paymentProofs: proofs,
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
    }
}

private final class FakeReceiptSdk: PaykitReceiptSdk, @unchecked Sendable {
    private let requests: [PaymentRequestRecord]
    private var issued: [String: ReceiptIssuanceView] = [:]
    enum DrainOutcome { case sent, failed, none, unreachable }

    var issueFails = false
    var drainOutcome = DrainOutcome.sent
    private(set) var issuedCount = 0
    private(set) var drainedCounterparties: [String] = []

    init(requests: [PaymentRequestRecord]) {
        self.requests = requests
    }

    func identityStatus(priority _: PaykitSdkOperationLock.Priority) async throws -> IdentityStatus? {
        IdentityStatus(
            publicKey: "pubkyc3mduedw686dysw8ndr5c1dyry5h8k6i8hzbbmx9gf9k43zq4s9o",
            capability: .privateLinkCapable
        )
    }

    func sharedPaymentRequests(priority _: PaykitSdkOperationLock.Priority) async throws -> [PaymentRequestRecord] {
        requests
    }

    func issueReceipt(
        counterparty: String,
        draft: ReceiptDraft,
        priority _: PaykitSdkOperationLock.Priority
    ) async throws -> ReceiptIssuanceView {
        issuedCount += 1
        if issueFails {
            throw URLError(.notConnectedToInternet)
        }
        let receiptId = try XCTUnwrap(draft.receiptId)
        let view = ReceiptIssuanceView(
            counterparty: counterparty, appId: "bitkit", receiptId: receiptId, receiptAccessEventId: "access-1",
            paymentReference: draft.paymentReference, paymentRequestId: draft.paymentRequestId, billingPeriod: draft.billingPeriod,
            paymentEndpointIdentifier: draft.paymentEndpointIdentifier, amount: draft.amount, status: .accessQueued,
            outboundMessageId: 7, createdAt: "2027-01-15T08:02:00Z", updatedAt: "2027-01-15T08:02:00Z",
            storedAt: "2027-01-15T08:02:00Z", accessQueuedAt: "2027-01-15T08:02:00Z"
        )
        issued[receiptId] = view
        return view
    }

    func issuedReceipts(priority _: PaykitSdkOperationLock.Priority) async throws -> [ReceiptIssuanceView] {
        Array(issued.values)
    }

    func processOutboundPrivateMessages(
        counterparty: String,
        priority _: PaykitSdkOperationLock.Priority,
        expectedIdentity _: String?
    ) async throws -> OutboundPrivateSendReport {
        drainedCounterparties.append(counterparty)
        if drainOutcome == .unreachable {
            throw URLError(.cannotConnectToHost)
        }
        let failure = OutboundPrivateSendFailure(outboundMessageId: 7, error: PrivateOperationError(noPointer: .init()))
        return OutboundPrivateSendReport(
            attempted: drainOutcome == .none ? [] : [7],
            sent: drainOutcome == .sent ? [7] : [],
            failed: drainOutcome == .failed ? [failure] : [],
            reservationCleanupFailures: [],
            recoveryMarkerFailures: []
        )
    }
}
