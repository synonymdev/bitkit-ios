@testable import Bitkit
import XCTest

final class MoveToSparkMathTests: XCTestCase {
    func testFirstCandidateLeavesRoomForAGuessedFee() {
        let amount = MoveToSparkMath.firstCandidate(wantedSats: 100_000, limitSats: 100_000)
        XCTAssertLessThan(amount, 100_000)
        XCTAssertEqual(amount, 100_000 - 500 - 2)
    }

    func testFirstCandidateKeepsASmallerTarget() {
        XCTAssertEqual(MoveToSparkMath.firstCandidate(wantedSats: 50000, limitSats: 100_000), 50000)
    }

    func testAmountAfterFeeFitsUnderTheLimit() {
        XCTAssertEqual(MoveToSparkMath.amountAfterFee(limitSats: 1_000_000, feeSats: 9000), 990_998)
        XCTAssertEqual(MoveToSparkMath.amountAfterFee(limitSats: 5, feeSats: 9000), 0)
    }

    func testFeeCapCoversTheQuotedFeeAndItsMargin() {
        XCTAssertEqual(MoveToSparkMath.feeCapMsat(feeSats: 30), 32000)
    }

    func testSmallerAmountHalvesUntilTheMinimum() {
        XCTAssertEqual(MoveToSparkMath.smallerAmount(100_000), 50000)
        XCTAssertNil(MoveToSparkMath.smallerAmount(MoveToSparkMath.minMoveSats))
    }

    func testMoveIsOfferedOnlyWithAUsableSpark() {
        XCTAssertFalse(MoveToSparkMath.canMove(channels: [], isSparkUsable: true))
        XCTAssertFalse(MoveToSparkMath.canMove(channels: nil, isSparkUsable: false))
    }
}
