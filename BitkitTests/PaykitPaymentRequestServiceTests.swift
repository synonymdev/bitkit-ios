@testable import Bitkit
import Foundation
import Paykit
import XCTest

@MainActor
final class PaykitPaymentRequestServiceTests: XCTestCase {
    func testContactPaymentContextClaimIsExclusiveAndIdentityBased() {
        let app = AppViewModel()
        let first = ContactPaymentContext(publicKey: "pubkycontact")
        let second = ContactPaymentContext(publicKey: "pubkycontact")

        XCTAssertTrue(app.claimContactPaymentContext(first))
        XCTAssertTrue(app.ownsContactPaymentContext(first))
        XCTAssertFalse(app.ownsContactPaymentContext(second))
        XCTAssertFalse(app.claimContactPaymentContext(second))

        app.resetSendState(preservingContactPaymentContext: true)
        XCTAssertTrue(app.ownsContactPaymentContext(first))
        app.resetSendState()
        XCTAssertFalse(app.ownsContactPaymentContext(first))
        XCTAssertTrue(app.claimContactPaymentContext(second))
    }

    func testRefreshMapsSupportedOneTimeBitcoinRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let currentOnchain = PublicPaykitService.MethodId.onchainMethodId(network: Env.network, scriptType: .p2wpkh)
        let otherOnchain: PublicPaykitService.MethodId = Env.network == .bitcoin ? .testnetOnchainP2wpkh : .bitcoinOnchainP2wpkh
        let record = try paymentRequestRecord(
            amount: "0.00100000000",
            expiresAt: timestamp(now.addingTimeInterval(60)),
            endpoints: [
                PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                currentOnchain.rawValue,
                otherOnchain.rawValue,
                "btc-unsupported-method",
            ],
            metadata: #"{"order":"123"}"#
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let clock = PaymentRequestTestClock(now)
        let manager = paymentRequestManager(sdk: sdk, clock: clock)

        await manager.refresh()

        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertEqual(manager.pendingRequests.count, 1)
        XCTAssertEqual(request.paymentRequestId, record.paymentRequestId)
        XCTAssertEqual(request.amountValue, "0.00100000000")
        XCTAssertEqual(request.amountSats, 100_000)
        XCTAssertEqual(request.paymentReference, "invoice-123")
        XCTAssertEqual(request.metadata, #"{"order":"123"}"#)
        XCTAssertEqual(
            request.acceptedPaymentEndpointIdentifiers,
            [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue, currentOnchain.rawValue]
        )
    }

    func testRefreshDropsExpiredAndUnsupportedRequests() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: timestamp(now),
            anchor: timestamp(now),
            endsAt: nil
        )
        let records = try [
            paymentRequestRecord(id: "valid"),
            paymentRequestRecord(id: "sdk-expired", state: .proposalExpired),
            paymentRequestRecord(id: "timestamp-expired", expiresAt: timestamp(now)),
            paymentRequestRecord(id: "malformed-expiry", expiresAt: "not-a-timestamp"),
            paymentRequestRecord(id: "wrong-role", role: .payee),
            paymentRequestRecord(id: "recurring", recurrence: recurrence),
            paymentRequestRecord(id: "wrong-asset", asset: "usd"),
            paymentRequestRecord(id: "sub-satoshi", amount: "0.000000001"),
            paymentRequestRecord(id: "zero", amount: "0"),
            paymentRequestRecord(id: "unsupported-endpoint", endpoints: ["btc-unsupported-method"]),
        ]
        let sdk = PaymentRequestSdkMock(records: records)
        let clock = PaymentRequestTestClock(now)
        let manager = paymentRequestManager(sdk: sdk, clock: clock)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["valid"])
    }

    func testRefreshRejectsAmountsOutsideTheAppPaymentRange() async throws {
        let records = try [
            paymentRequestRecord(id: "one-sat", amount: "0.00000001"),
            paymentRequestRecord(id: "millisatoshi-safe-max", amount: "184467440.73709551"),
            paymentRequestRecord(id: "millisatoshi-overflow", amount: "184467440.73709552"),
            paymentRequestRecord(id: "int-max", amount: "92233720368.54775807"),
            paymentRequestRecord(id: "int-overflow", amount: "92233720368.54775808"),
            paymentRequestRecord(id: "uint64-max", amount: "184467440737.09551615"),
            paymentRequestRecord(id: "uint64-overflow", amount: "184467440737.09551616"),
        ]
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: records))

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["one-sat", "millisatoshi-safe-max"])
        XCTAssertEqual(manager.pendingRequests.map(\.amountSats), [1, UInt64.max / 1000])
    }

    func testPaymentAndLightningInvoiceAmountsMustMatchRequest() throws {
        let request = try XCTUnwrap(PaykitPaymentRequest(
            record: paymentRequestRecord(amount: "0.000025"),
            now: Date()
        ))

        XCTAssertTrue(request.acceptsPaymentAmount(2500))
        XCTAssertFalse(request.acceptsPaymentAmount(0))
        XCTAssertFalse(request.acceptsPaymentAmount(2501))
        XCTAssertTrue(request.acceptsLightningInvoiceAmount(milliSatoshis: nil))
        XCTAssertTrue(request.acceptsLightningInvoiceAmount(milliSatoshis: 2_500_000))
        XCTAssertFalse(request.acceptsLightningInvoiceAmount(milliSatoshis: 2_499_999))
        XCTAssertFalse(request.acceptsLightningInvoiceAmount(milliSatoshis: 2_500_001))
    }

    func testRefreshContinuesWhenPendingResponseDeliveryFails() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        await sdk.failNextProcess()
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.processCallCount, 1)
        XCTAssertEqual(snapshot.receiveCallCount, 1)
    }

    func testFailedRefreshKeepsPreviouslyLoadedRequests() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        await sdk.setRecords([])
        await sdk.setReceiveError(.receive)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
    }

    func testManagerDropsRequestWhenItExpiresWithoutAnotherRefresh() async throws {
        let expiresAt = Date().addingTimeInterval(2)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(expiresAt))])
        let now: @Sendable () -> Date = { Date() }
        let manager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, now: now, logWarning: { _ in }),
            now: now,
            logWarning: { _ in }
        )
        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
        try await waitUntil(timeout: .seconds(5)) { manager.pendingRequests.isEmpty }
    }

    func testPresentedRequestRemainsPendingWithoutBeingPresentedAgain() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)

        XCTAssertTrue(manager.markPresentedIfPending(request))
        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
    }

    func testExpiredRequestCannotBeMarkedPresented() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(60)))])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)
        clock.advance(by: 61)

        XCTAssertFalse(manager.markPresentedIfPending(request))
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testAcceptQueuesResponseAndRemovesRequest() async throws {
        let sharedId = "550e8400-e29b-41d4-a716-446655440000"
        let firstRecord = try paymentRequestRecord(id: sharedId)
        let secondRecord = try paymentRequestRecord(
            id: sharedId,
            counterpartyReceiverPath: PaykitReceiverPath.wallet
        )
        let thirdRecord = try paymentRequestRecord(id: sharedId, counterparty: "pubkyother")
        let fourthRecord = try paymentRequestRecord(id: "650e8400-e29b-41d4-a716-446655440000")
        let remainingIds = [secondRecord, thirdRecord, fourthRecord].map {
            PaykitPaymentRequest.ID(
                paymentRequestId: $0.paymentRequestId,
                counterparty: $0.counterparty,
                counterpartyReceiverPath: $0.counterpartyReceiverPath
            )
        }
        let sdk = PaymentRequestSdkMock(records: [firstRecord, secondRecord, thirdRecord, fourthRecord])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first(where: {
            $0.paymentRequestId == firstRecord.paymentRequestId &&
                $0.counterparty == firstRecord.counterparty &&
                $0.counterpartyReceiverPath == firstRecord.counterpartyReceiverPath
        }))

        try await manager.accept(request)

        XCTAssertEqual(manager.pendingRequests.map(\.id), remainingIds)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(
            snapshot.acceptedRequests,
            [PaymentRequestInvocation(
                counterparty: request.counterparty,
                counterpartyReceiverPath: request.counterpartyReceiverPath,
                paymentRequestId: request.paymentRequestId
            )]
        )
    }

    func testAcceptRechecksExpirationImmediatelyBeforeAction() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(60)))])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        clock.advance(by: 61)

        do {
            try await manager.accept(request)
            XCTFail("Expected the expired request to be rejected locally")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired)
        }

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.acceptedRequests.isEmpty)
    }

    func testQueuedAcceptanceSucceedsWhenImmediateDeliveryFails() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.failNextProcess()

        try await manager.accept(request)

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [request.paymentRequestId])
        XCTAssertEqual(snapshot.processCallCount, 2)
    }

    func testQueuedAcceptanceSucceedsWhenImmediateDeliveryIsCancelled() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.cancelNextProcess()

        try await manager.accept(request)

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [request.paymentRequestId])
        XCTAssertEqual(snapshot.processCallCount, 2)
    }

    func testAcceptInvalidatesAnOverlappingRefreshSnapshot() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextPaymentRequestList()

        let refreshTask = Task { await manager.refresh() }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }
        try await manager.accept(request)
        await sdk.resumePaymentRequestList()
        await refreshTask.value

        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testClearSuppressesStateChangesFromAnInFlightAccept() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextAccept()

        let acceptTask = Task { try await manager.accept(request) }
        try await waitUntil { await sdk.acceptIsPaused() }
        manager.clear()
        await sdk.resumeAccept()
        try await acceptTask.value

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.receiveCallCount, 1)
    }

    private func paymentRequestManager(
        sdk: PaymentRequestSdkMock,
        clock: PaymentRequestTestClock = PaymentRequestTestClock(Date())
    ) -> PaykitPaymentRequestManager {
        let now: @Sendable () -> Date = { clock.now() }
        return PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, now: now, logWarning: { _ in }),
            now: now,
            logWarning: { _ in }
        )
    }

    private func paymentRequestRecord(
        id: String = "550e8400-e29b-41d4-a716-446655440000",
        counterparty: String = "pubkypayee",
        counterpartyReceiverPath: String = PaykitReceiverPath.server,
        state: PaymentRequestLifecycleState = .proposed,
        role: PaymentRequestLocalRole? = .payer,
        amount: String = "0.001",
        asset: String = "btc",
        expiresAt: String? = nil,
        recurrence: PaymentRequestRecurrence? = nil,
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        metadata: String = "{}"
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            paymentRequestId: id,
            localRole: role,
            state: state,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: amount, asset: asset),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: expiresAt,
                recurrence: recurrence,
                acceptedPaymentEndpointIdentifiers: endpoints,
                metadata: PrivateJsonObject(text: metadata)
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private actor PaymentRequestSdkMock: PaykitPaymentRequestSdkHandling {
    private var records: [PaymentRequestRecord]
    private var processCallCount = 0
    private var receiveCallCount = 0
    private var processFailuresRemaining = 0
    private var processCancellationsRemaining = 0
    private var receiveError: PaymentRequestSdkMockError?
    private var acceptedRequests: [PaymentRequestInvocation] = []
    private var shouldPauseNextPaymentRequestList = false
    private var isPaymentRequestListPaused = false
    private var paymentRequestListContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseNextAccept = false
    private var isAcceptPaused = false
    private var acceptContinuation: CheckedContinuation<Void, Never>?

    init(records: [PaymentRequestRecord]) {
        self.records = records
    }

    func processPendingPrivateMessages() throws -> [OutboundPrivateCounterpartySendReport] {
        processCallCount += 1
        if processCancellationsRemaining > 0 {
            processCancellationsRemaining -= 1
            throw CancellationError()
        }
        guard processFailuresRemaining > 0 else { return [] }
        processFailuresRemaining -= 1
        throw PaymentRequestSdkMockError.process
    }

    func receivePrivateMessagesFromLinkedPeers() throws -> [PrivateStreamCounterpartyIntakeReport] {
        receiveCallCount += 1
        if let receiveError {
            throw receiveError
        }
        return []
    }

    func actionableReceivedPaymentRequests() async -> [PaymentRequestRecord] {
        let snapshot = records
        guard shouldPauseNextPaymentRequestList else { return snapshot }

        shouldPauseNextPaymentRequestList = false
        isPaymentRequestListPaused = true
        await withCheckedContinuation { paymentRequestListContinuation = $0 }
        isPaymentRequestListPaused = false
        return snapshot
    }

    func acceptPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String
    ) async throws -> PaymentRequestRecord {
        if shouldPauseNextAccept {
            shouldPauseNextAccept = false
            isAcceptPaused = true
            await withCheckedContinuation { acceptContinuation = $0 }
            isAcceptPaused = false
        }

        let record = try removeRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            id: paymentRequestId
        )
        acceptedRequests.append(PaymentRequestInvocation(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            paymentRequestId: paymentRequestId
        ))
        return record
    }

    func failNextProcess() {
        processFailuresRemaining += 1
    }

    func cancelNextProcess() {
        processCancellationsRemaining += 1
    }

    func pauseNextPaymentRequestList() {
        shouldPauseNextPaymentRequestList = true
    }

    func paymentRequestListIsPaused() -> Bool {
        isPaymentRequestListPaused
    }

    func resumePaymentRequestList() {
        paymentRequestListContinuation?.resume()
        paymentRequestListContinuation = nil
    }

    func pauseNextAccept() {
        shouldPauseNextAccept = true
    }

    func acceptIsPaused() -> Bool {
        isAcceptPaused
    }

    func resumeAccept() {
        acceptContinuation?.resume()
        acceptContinuation = nil
    }

    func setRecords(_ records: [PaymentRequestRecord]) {
        self.records = records
    }

    func setReceiveError(_ error: PaymentRequestSdkMockError?) {
        receiveError = error
    }

    func snapshot() -> PaymentRequestSdkSnapshot {
        PaymentRequestSdkSnapshot(
            processCallCount: processCallCount,
            receiveCallCount: receiveCallCount,
            acceptedRequests: acceptedRequests
        )
    }

    private func removeRecord(
        counterparty: String,
        counterpartyReceiverPath: String,
        id: String
    ) throws -> PaymentRequestRecord {
        guard let index = records.firstIndex(where: {
            $0.counterparty == counterparty &&
                $0.counterpartyReceiverPath == counterpartyReceiverPath &&
                $0.paymentRequestId == id
        }) else {
            throw PaymentRequestSdkMockError.requestMissing
        }
        return records.remove(at: index)
    }
}

private struct PaymentRequestSdkSnapshot {
    let processCallCount: Int
    let receiveCallCount: Int
    let acceptedRequests: [PaymentRequestInvocation]
}

private struct PaymentRequestInvocation: Equatable {
    let counterparty: String
    let counterpartyReceiverPath: String
    let paymentRequestId: String
}

private enum PaymentRequestSdkMockError: Error {
    case process
    case receive
    case requestMissing
}

private final class PaymentRequestTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}

private enum PaymentRequestTestError: Error {
    case timedOut
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await !condition() {
        guard clock.now < deadline else { throw PaymentRequestTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}
