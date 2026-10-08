@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtSupportDetailsTests: XCTestCase {
    func testTransferSupportIncludesProviderReferencesAndTransactions() {
        var transfer = UsdtTransfer(
            id: "local-id", txHash: "source-tx", userOperationHash: nil, bridgeGuid: "message-id", orchestra: nil,
            recipient: "recipient-address", destination: .polygon, amount: 100, receivedAmount: 90,
            fee: 10, isIncoming: false, status: .bridgeNeedsAttention, timestamp: 1
        )
        XCTAssertTrue(transfer.supportDetails.contains("Bridge: USDT0"))
        XCTAssertTrue(transfer.supportDetails.contains("LayerZero message: message-id"))
        XCTAssertFalse(transfer.supportDetails.contains("Destination transaction:"))

        transfer.bridgeGuid = nil
        transfer.orchestra = UsdtOrchestraTransfer(
            quoteId: "order-id", fundingAddress: "funding-address", destinationTx: "destination-tx",
            refundTx: "refund-tx", refundAmount: 90
        )
        let details = transfer.supportDetails
        for value in ["Orchestra", "Arbitrum One", "Polygon", "order-id", "source-tx", "destination-tx", "refund-tx"] {
            XCTAssertTrue(details.contains(value), value)
        }
        XCTAssertFalse(details.contains("recipient-address"))
        XCTAssertFalse(details.contains("funding-address"))
    }

    func testDepositSupportUsesCurrentOrderStatusAndRefund() {
        let deposit = UsdtDeposit(id: "deposit-id", network: "tron", asset: "USDT", amount: 100, sourceTx: "source-tx",
                                  status: "held", code: "old-code", refundTx: "deposit-refund")
        var detail = UsdtDepositDetail(deposit: deposit, order: nil)
        XCTAssertTrue(detail.supportDetails.contains("Status code: old-code"))
        XCTAssertTrue(detail.supportDetails.contains("Refund transaction: deposit-refund"))
        detail.order = UsdtDepositOrder(status: "refunded", amountIn: 100, amountOut: nil,
                                        destinationTx: nil, refundTx: "order-refund", code: nil)
        let details = detail.supportDetails
        for value in ["Orchestra", "tron", "Arbitrum One", "deposit-id", "source-tx", "refunded", "order-refund"] {
            XCTAssertTrue(details.contains(value), value)
        }
        XCTAssertFalse(details.contains("old-code"))
        XCTAssertFalse(details.contains("deposit-refund"))
    }
}
