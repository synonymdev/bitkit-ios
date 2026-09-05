@testable import Bitkit
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

private final class FakeOnchainPayment: OnchainPayment {
    enum Invocation: Equatable {
        case sendToAddress(address: String, amountSats: UInt64)
        case sendAllToAddress(address: String, retainReserve: Bool)
    }

    private let result: () throws -> Txid
    private(set) var invocation: Invocation?

    init(result: @escaping () throws -> Txid) {
        self.result = result
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
}
