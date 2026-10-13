@testable import Bitkit
import BitkitCore
import XCTest

final class WalletActivityTests: XCTestCase {
    func testMergedActivityPositionsIncludeDateHeaders() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let timestamp = UInt64(today.timeIntervalSince1970)
        let sent = Activity.lightning(LightningActivity(
            walletId: WalletScope.default, id: "sent", txType: .sent, status: .succeeded, value: 1000, fee: 0,
            invoice: "invoice", message: "", timestamp: timestamp + 2, preimage: nil, contact: nil,
            createdAt: nil, updatedAt: nil, seenAt: nil
        ))
        let received = UsdtTransfer(
            sender: nil, id: "received", txHash: "tx", userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
            recipient: "recipient", destination: .arbitrum, amount: 1_000_000, receivedAmount: 1_000_000, fee: nil,
            isIncoming: true, status: .confirmed, timestamp: timestamp + 1
        )
        var earlier = received
        earlier.id = "earlier"
        earlier.timestamp = UInt64(yesterday.timeIntervalSince1970)

        let grouped = WalletActivity.grouped(WalletActivity.merged([sent], [earlier, received]))
        XCTAssertEqual(grouped, [
            .header(DateFormatterHelpers.getActivityGroupHeader(for: today)),
            .activity(.bitcoin(sent)),
            .activity(.usdt(received)),
            .header(DateFormatterHelpers.getActivityGroupHeader(for: yesterday)),
            .activity(.usdt(earlier)),
        ])
        XCTAssertTrue(WalletActivity.grouped([]).isEmpty)
    }
}
