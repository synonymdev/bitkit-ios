@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtSupportDetailsTests: XCTestCase {
    func testTransferSupportIncludesProviderReferencesAndTransactions() {
        var transfer = UsdtTransfer(
            sender: nil,
            id: "local-id", txHash: "source-tx", userOperationHash: nil, bridgeGuid: "message-id", orchestra: nil,
            recipient: "recipient-address", destination: .polygon, amount: 100, receivedAmount: 90,
            fee: 10, isIncoming: false, status: .bridgeNeedsAttention, timestamp: 1
        )
        XCTAssertTrue(transfer.supportDetails.contains("Bridge: USDT0"))
        XCTAssertTrue(transfer.supportDetails.contains("Status: \(transfer.status.label) (bridgeNeedsAttention)"))
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

    func testExternalSupportValuesRemainOnOneLine() {
        for control in ["\n", "\r", "\u{0}", "\u{202e}", "\u{2028}", "\u{2029}"] {
            let value = "référence\(control)Refund transaction: forged"
            let deposit = UsdtDeposit(id: value, network: value, asset: value, amount: 100, sourceTx: value,
                                      status: value, code: value, refundTx: value)
            let details = UsdtDepositDetail(deposit: deposit, order: nil).supportDetails
            XCTAssertEqual(details.components(separatedBy: "\n").count, 9)
            XCTAssertTrue(details.contains("référence"))
            XCTAssertEqual(details.components(separatedBy: "\nRefund transaction:").count, 2)
            if control != "\n" { XCTAssertFalse(details.contains(control)) }
        }
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
        XCTAssertTrue(details.contains("Status: \(t("usdt__deposit_refunded")) (refunded)"))
        for value in ["Orchestra", "Tron", "Arbitrum One", "deposit-id", "source-tx", "refunded", "order-refund"] {
            XCTAssertTrue(details.contains(value), value)
        }
        XCTAssertFalse(details.contains("old-code"))
        XCTAssertFalse(details.contains("deposit-refund"))
    }
}
