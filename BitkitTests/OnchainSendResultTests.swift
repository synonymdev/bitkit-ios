@testable import Bitkit
import Foundation
import LDKNode
import XCTest

final class OnchainSendResultTests: XCTestCase {
    private let feeRate = FeeRate.fromSatPerKwu(satKwu: 253)

    func testAmountSendReturnsAcceptedTransactionId() throws {
        let payment = FakeOnchainPayment { "accepted-txid" }

        let txid = try LightningService.executeOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: false
        )

        XCTAssertEqual(txid, "accepted-txid")
        XCTAssertEqual(payment.invocation, .sendToAddress(address: "recipient", amountSats: 1000))
    }

    func testMaxSendReturnsAcceptedTransactionId() throws {
        let payment = FakeOnchainPayment { "accepted-max-txid" }

        let txid = try LightningService.executeOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: true
        )

        XCTAssertEqual(txid, "accepted-max-txid")
        XCTAssertEqual(payment.invocation, .sendAllToAddress(address: "recipient", retainReserve: true))
    }

    func testRejectedBroadcastIsPropagated() {
        assertBroadcastErrorIsPropagated(
            .OnchainTxBroadcastRejected(txid: "rejected-txid"),
            expectedFailureType: "OnchainTxBroadcastRejected"
        )
    }

    func testFailedBroadcastIsPropagated() {
        assertBroadcastErrorIsPropagated(
            .OnchainTxBroadcastFailed(txid: "failed-txid"),
            expectedFailureType: "OnchainTxBroadcastFailed"
        )
    }

    func testTimedOutBroadcastIsPropagated() {
        assertBroadcastErrorIsPropagated(
            .OnchainTxBroadcastTimeout(txid: "timed-out-txid"),
            expectedFailureType: "OnchainTxBroadcastTimeout"
        )
    }

    func testNotDispatchedBroadcastIsPropagated() {
        assertBroadcastErrorIsPropagated(
            .OnchainTxBroadcastNotDispatched(txid: "not-dispatched-txid"),
            expectedFailureType: "OnchainTxBroadcastNotDispatched"
        )
    }

    func testBroadcastErrorsRemainIdentifiableWhenWrapped() {
        let cases: [(NodeError, String, String, String)] = [
            (.OnchainTxBroadcastRejected(txid: "rejected-txid"), "Onchain transaction was rejected", "OnchainTxBroadcastRejected", "rejected-txid"),
            (.OnchainTxBroadcastFailed(txid: "failed-txid"), "Failed to broadcast onchain transaction", "OnchainTxBroadcastFailed", "failed-txid"),
            (
                .OnchainTxBroadcastTimeout(txid: "timed-out-txid"),
                "Onchain transaction broadcast timed out",
                "OnchainTxBroadcastTimeout",
                "timed-out-txid"
            ),
            (
                .OnchainTxBroadcastNotDispatched(txid: "not-dispatched-txid"),
                "Onchain transaction was not dispatched",
                "OnchainTxBroadcastNotDispatched",
                "not-dispatched-txid"
            ),
        ]

        for (nodeError, expectedMessage, expectedFailureType, expectedTxid) in cases {
            let appError = Bitkit.AppError(error: nodeError)

            XCTAssertEqual(appError.message, expectedMessage)
            XCTAssertTrue(appError.debugMessage?.contains(expectedTxid) == true)
            XCTAssertEqual(sendFailureType(for: appError), expectedFailureType)
        }
    }

    func testFailedAndTimedOutBroadcastsPreservePendingTransactionId() {
        let cases: [(NodeError, String)] = [
            (.OnchainTxBroadcastFailed(txid: "failed-txid"), "failed-txid"),
            (.OnchainTxBroadcastTimeout(txid: "timed-out-txid"), "timed-out-txid"),
        ]

        for (error, expectedTxid) in cases {
            XCTAssertEqual(
                pendingOnchainBroadcastContext(for: error),
                PendingOnchainBroadcastErrorContext(txid: expectedTxid, source: .currentPayment)
            )
            XCTAssertEqual(
                pendingOnchainBroadcastContext(for: Bitkit.AppError(error: error)),
                PendingOnchainBroadcastErrorContext(txid: expectedTxid, source: .currentPayment)
            )
        }
    }

    func testConclusiveBroadcastErrorsRemainRetryableFreshSends() {
        XCTAssertNil(pendingOnchainBroadcastContext(for: NodeError.OnchainTxBroadcastRejected(txid: "rejected-txid")))
        XCTAssertNil(pendingOnchainBroadcastContext(for: NodeError.OnchainTxBroadcastNotDispatched(txid: "not-dispatched-txid")))
    }

    func testExistingPendingBroadcastPreventsFreshSpend() {
        let pending = PendingBroadcastInfo(txid: "pending-txid", lineage: ["pending-txid"])
        let payment = FakeOnchainPayment(pendingResult: { [pending] }) { "unexpected-txid" }

        XCTAssertThrowsError(try LightningService.executeOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: false
        )) { error in
            XCTAssertEqual(
                pendingOnchainBroadcastContext(for: error),
                PendingOnchainBroadcastErrorContext(txid: "pending-txid", source: .existingPayment)
            )
            XCTAssertEqual(
                pendingOnchainBroadcastContext(for: Bitkit.AppError(error: error)),
                PendingOnchainBroadcastErrorContext(txid: "pending-txid", source: .existingPayment)
            )
        }
        XCTAssertNil(payment.invocation)
    }

    func testExistingPendingBroadcastSkipsBeforeBroadcastAttempt() async {
        let pending = PendingBroadcastInfo(txid: "pending-txid", lineage: ["pending-txid"])
        let payment = FakeOnchainPayment(pendingResult: { [pending] }) { "unexpected-txid" }
        let beforeBroadcastAttemptCalled = ThreadSafeFlag()

        do {
            _ = try await LightningService.performOnchainSend(
                onchainPayment: payment,
                address: "recipient",
                sats: 1000,
                feeRate: feeRate,
                utxosToSpend: nil,
                isMaxAmount: false,
                beforeBroadcastAttempt: { beforeBroadcastAttemptCalled.set() }
            )
            XCTFail("Expected the pending broadcast to prevent a new attempt")
        } catch {
            XCTAssertEqual(
                pendingOnchainBroadcastContext(for: error),
                PendingOnchainBroadcastErrorContext(txid: "pending-txid", source: .existingPayment)
            )
        }

        XCTAssertFalse(beforeBroadcastAttemptCalled.value)
        XCTAssertNil(payment.invocation)
    }

    func testBeforeBroadcastAttemptRunsBeforeTransactionCreation() async throws {
        let beforeBroadcastAttemptCalled = ThreadSafeFlag()
        let payment = FakeOnchainPayment {
            XCTAssertTrue(beforeBroadcastAttemptCalled.value)
            return "accepted-txid"
        }

        let txid = try await LightningService.performOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: false,
            beforeBroadcastAttempt: { beforeBroadcastAttemptCalled.set() }
        )

        XCTAssertEqual(txid, "accepted-txid")
    }

    func testPendingBroadcastQueryFailurePreventsFreshSpend() {
        let payment = FakeOnchainPayment(pendingResult: { throw QueryError.failed }) { "unexpected-txid" }

        XCTAssertThrowsError(try LightningService.executeOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: true
        ))
        XCTAssertNil(payment.invocation)
    }

    func testPendingCheckAndTransactionCreationAreSerialized() async {
        let payment = SerializingFakeOnchainPayment()

        async let firstResult = pendingContextForSerializedSend(
            payment: payment,
            feeRate: feeRate
        )
        async let secondResult = pendingContextForSerializedSend(
            payment: payment,
            feeRate: feeRate
        )
        let contexts = await [firstResult, secondResult]

        XCTAssertEqual(payment.sendInvocationCount, 1)
        XCTAssertEqual(contexts.compactMap(\.self).filter { $0.source == .currentPayment }.count, 1)
        XCTAssertEqual(contexts.compactMap(\.self).filter { $0.source == .existingPayment }.count, 1)
    }

    func testPendingBroadcastUsesExactTransactionForRetry() throws {
        let payment = FakeOnchainPayment(rebroadcastResult: { txid in "accepted-\(txid)" }) { "unused" }

        let txid = try LightningService.rebroadcastOnchainTransaction(onchainPayment: payment, txid: "pending-txid")

        XCTAssertEqual(txid, "accepted-pending-txid")
        XCTAssertEqual(payment.invocation, .rebroadcast(txid: "pending-txid"))
    }

    func testPendingOutcomeFollowsOriginalTransactionToActiveReplacement() throws {
        let replacement = BroadcastOutcome(
            status: .pending,
            txid: "replacement-txid",
            lineage: ["original-txid", "replacement-txid"]
        )
        let payment = FakeOnchainPayment(outcomeResult: { _ in replacement }) { "unused" }

        let outcome = try LightningService.onchainBroadcastOutcome(
            onchainPayment: payment,
            txid: "original-txid"
        )

        XCTAssertEqual(outcome, replacement)
        XCTAssertEqual(payment.invocation, .broadcastOutcome(txid: "original-txid"))
    }

    func testTerminalOutcomeAcknowledgesOriginalLineageTransaction() throws {
        let payment = FakeOnchainPayment { "unused" }

        try LightningService.acknowledgeOnchainBroadcastOutcome(
            onchainPayment: payment,
            txid: "original-txid"
        )

        XCTAssertEqual(payment.invocation, .acknowledgeOutcome(txid: "original-txid"))
    }

    func testConclusiveErrorsDoNotPersistFreshSpendBlocker() throws {
        for error in [
            NodeError.OnchainTxBroadcastRejected(txid: "rejected-txid"),
            NodeError.OnchainTxBroadcastNotDispatched(txid: "not-dispatched-txid"),
        ] {
            let rejectedPayment = FakeOnchainPayment { throw error }
            XCTAssertThrowsError(try LightningService.executeOnchainSend(
                onchainPayment: rejectedPayment,
                address: "recipient",
                sats: 1000,
                feeRate: feeRate,
                utxosToSpend: nil,
                isMaxAmount: false
            ))

            let nextPayment = FakeOnchainPayment { "accepted-txid" }
            XCTAssertEqual(try LightningService.executeOnchainSend(
                onchainPayment: nextPayment,
                address: "recipient",
                sats: 1000,
                feeRate: feeRate,
                utxosToSpend: nil,
                isMaxAmount: false
            ), "accepted-txid")
        }
    }

    func testAcceptedReplacementRemainsResolvableAfterPendingWindow() throws {
        let replacement = BroadcastOutcome(
            status: .accepted,
            txid: "replacement-txid",
            lineage: ["original-txid", "replacement-txid"]
        )
        let payment = FakeOnchainPayment(outcomeResult: { _ in replacement }) { "unused" }

        let outcome = try LightningService.onchainBroadcastOutcome(
            onchainPayment: payment,
            txid: "original-txid"
        )

        XCTAssertEqual(outcome, replacement)
    }

    private func assertBroadcastErrorIsPropagated(
        _ broadcastError: NodeError,
        expectedFailureType: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payment = FakeOnchainPayment { throw broadcastError }

        XCTAssertThrowsError(try LightningService.executeOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: false
        ), file: file, line: line) { error in
            XCTAssertEqual(sendFailureType(for: error), expectedFailureType, file: file, line: line)
        }
    }
}

private func pendingContextForSerializedSend(
    payment: OnchainPayment,
    feeRate: FeeRate
) async -> PendingOnchainBroadcastErrorContext? {
    do {
        _ = try await LightningService.performOnchainSend(
            onchainPayment: payment,
            address: "recipient",
            sats: 1000,
            feeRate: feeRate,
            utxosToSpend: nil,
            isMaxAmount: false
        )
        return nil
    } catch {
        return pendingOnchainBroadcastContext(for: error)
    }
}

private final class FakeOnchainPayment: OnchainPayment {
    enum Invocation: Equatable {
        case sendToAddress(address: String, amountSats: UInt64)
        case sendAllToAddress(address: String, retainReserve: Bool)
        case rebroadcast(txid: Txid)
        case broadcastOutcome(txid: Txid)
        case acknowledgeOutcome(txid: Txid)
    }

    private let result: () throws -> Txid
    private let pendingResult: () throws -> [PendingBroadcastInfo]
    private let rebroadcastResult: (Txid) throws -> Txid
    private let outcomeResult: (Txid) throws -> BroadcastOutcome?
    private(set) var invocation: Invocation?

    init(
        pendingResult: @escaping () throws -> [PendingBroadcastInfo] = { [] },
        rebroadcastResult: @escaping (Txid) throws -> Txid = { $0 },
        outcomeResult: @escaping (Txid) throws -> BroadcastOutcome? = { _ in nil },
        result: @escaping () throws -> Txid
    ) {
        self.result = result
        self.pendingResult = pendingResult
        self.rebroadcastResult = rebroadcastResult
        self.outcomeResult = outcomeResult
        super.init(noPointer: .init())
    }

    @available(*, unavailable)
    required init(unsafeFromRawPointer _: UnsafeMutableRawPointer) {
        fatalError("init(unsafeFromRawPointer:) is unavailable")
    }

    override func sendToAddress(
        address: Address,
        amountSats: UInt64,
        feeRate _: FeeRate?,
        utxosToSpend _: [SpendableUtxo]?
    ) throws -> Txid {
        invocation = .sendToAddress(address: address, amountSats: amountSats)
        return try result()
    }

    override func sendAllToAddress(address: Address, retainReserve: Bool, feeRate _: FeeRate?) throws -> Txid {
        invocation = .sendAllToAddress(address: address, retainReserve: retainReserve)
        return try result()
    }

    override func listPendingBroadcasts() throws -> [PendingBroadcastInfo] {
        try pendingResult()
    }

    override func rebroadcastTransaction(txid: Txid) throws -> Txid {
        invocation = .rebroadcast(txid: txid)
        return try rebroadcastResult(txid)
    }

    override func broadcastOutcome(txid: Txid) throws -> BroadcastOutcome? {
        invocation = .broadcastOutcome(txid: txid)
        return try outcomeResult(txid)
    }

    override func acknowledgeBroadcastOutcome(txid: Txid) throws {
        invocation = .acknowledgeOutcome(txid: txid)
    }
}

private enum QueryError: Error {
    case failed
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

private final class SerializingFakeOnchainPayment: OnchainPayment {
    private var pendingBroadcast: PendingBroadcastInfo?
    private(set) var sendInvocationCount = 0

    init() {
        super.init(noPointer: .init())
    }

    @available(*, unavailable)
    required init(unsafeFromRawPointer _: UnsafeMutableRawPointer) {
        fatalError("init(unsafeFromRawPointer:) is unavailable")
    }

    override func listPendingBroadcasts() throws -> [PendingBroadcastInfo] {
        pendingBroadcast.map { [$0] } ?? []
    }

    override func sendToAddress(
        address _: Address,
        amountSats _: UInt64,
        feeRate _: FeeRate?,
        utxosToSpend _: [SpendableUtxo]?
    ) throws -> Txid {
        sendInvocationCount += 1
        pendingBroadcast = PendingBroadcastInfo(txid: "pending-txid", lineage: ["pending-txid"])
        throw NodeError.OnchainTxBroadcastTimeout(txid: "pending-txid")
    }
}
