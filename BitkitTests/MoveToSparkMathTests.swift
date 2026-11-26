@testable import Bitkit
import LDKNode
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

    func testFeeCapIsTheQuotedFee() {
        let feeSats = MoveToSparkMath.quotedFeeSats(estimateSats: 30)
        XCTAssertEqual(feeSats, 32)
        XCTAssertEqual(MoveToSparkMath.feeCapMsat(feeSats: feeSats), 32000)
        // Amount and quoted fee together fit under the limit.
        XCTAssertEqual(MoveToSparkMath.amountAfterFee(limitSats: 1_000_000, feeSats: 30) + feeSats, 1_000_000)
    }

    func testSmallerAmountHalvesUntilTheMinimum() {
        XCTAssertEqual(MoveToSparkMath.smallerAmount(100_000), 50000)
        XCTAssertNil(MoveToSparkMath.smallerAmount(MoveToSparkMath.minMoveSats))
    }

    func testMoveIsOfferedOnlyWhenTheMinimumFitsBesideTheFeeReserve() {
        XCTAssertFalse(MoveToSparkMath.hasMovableBalance(limitSats: 1011))
        XCTAssertTrue(MoveToSparkMath.hasMovableBalance(limitSats: 1012))
    }

    func testMoveIsOfferedOnlyWithAUsableSpark() {
        XCTAssertFalse(MoveToSparkMath.canMove(channels: [], isSparkUsable: true))
        XCTAssertFalse(MoveToSparkMath.canMove(channels: nil, isSparkUsable: false))
        let channel = ChannelDetails.mock(outboundCapacityMsat: 50_000_000)
        XCTAssertFalse(MoveToSparkMath.canMove(channels: [channel], isSparkUsable: false))
        XCTAssertTrue(MoveToSparkMath.canMove(channels: [channel], isSparkUsable: true))
    }

    func testSparkTakesNoMoveDuringAnExit() {
        XCTAssertTrue(MoveToSparkMath.isSparkUsable(isReady: true, isExiting: false))
        XCTAssertFalse(MoveToSparkMath.isSparkUsable(isReady: true, isExiting: true))
        XCTAssertFalse(MoveToSparkMath.isSparkUsable(isReady: false, isExiting: false))
    }
}
