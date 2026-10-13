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

        var future = received
        future.id = "future"
        future.timestamp = timestamp + 2 * 24 * 60 * 60
        var historical = received
        historical.id = "historical"
        let priorYear = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -1, to: today))
        historical.timestamp = UInt64(priorYear.timeIntervalSince1970)
        var older = historical
        older.id = "older"
        let olderYear = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -2, to: today))
        older.timestamp = UInt64(olderYear.timeIntervalSince1970)

        let grouped = WalletActivity.grouped(WalletActivity.merged([sent], [earlier, received, future, historical, older]))
        XCTAssertEqual(grouped, [
            .header(DateFormatterHelpers.getActivityGroupHeader(for: today)),
            .activity(.usdt(future)),
            .activity(.bitcoin(sent)),
            .activity(.usdt(received)),
            .header(DateFormatterHelpers.getActivityGroupHeader(for: yesterday)),
            .activity(.usdt(earlier)),
            .header(DateFormatterHelpers.getActivityGroupHeader(for: priorYear)),
            .activity(.usdt(historical)),
            .header(DateFormatterHelpers.getActivityGroupHeader(for: olderYear)),
            .activity(.usdt(older)),
        ])
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertTrue(WalletActivity.grouped([]).isEmpty)
    }
}
