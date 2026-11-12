@testable import Bitkit
import XCTest

final class SparkClaimFeeTests: XCTestCase {
    func testClaimFeeEstimateCoversTheClaimsSeenOnMainnet() {
        // Mainnet claims so far took 198 and 297 sats; the cap at 1 sat/vB stays above both.
        XCTAssertEqual(SparkManager.maxDepositClaimFeeSats(fastestFeeRate: 1, amountSats: 2500), 302)
        XCTAssertEqual(SparkManager.maxDepositClaimFeeSats(fastestFeeRate: 1, amountSats: 15000), 327)
    }
}
