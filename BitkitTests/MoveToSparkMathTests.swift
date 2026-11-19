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

    func testAMoveClosesOnlyTheChannelsItEmptied() {
        let before = [channel("a", sendableSats: 50000), channel("b", sendableSats: 20000), channel("c", sendableSats: 900)]
        let after = [channel("a", sendableSats: 0), channel("b", sendableSats: 20000), channel("c", sendableSats: 0)]
        let emptied = MoveToSparkMath.emptiedChannels(before: before, after: after)
        XCTAssertEqual(emptied.map(\.channelId), ["a"], "A channel that could send less than the move minimum was closed")
    }

    func testAMoveLeavesChannelsItDidNotKnowOrThatAreNotOpen() {
        let before = [channel("a", sendableSats: 50000)]
        let after = [channel("a", sendableSats: 0, isChannelReady: false), channel("new", sendableSats: 0)]
        XCTAssertTrue(MoveToSparkMath.emptiedChannels(before: before, after: after).isEmpty)
        XCTAssertTrue(MoveToSparkMath.emptiedChannels(before: before, after: nil).isEmpty)
    }

    private func channel(_ id: String, sendableSats: UInt64, isChannelReady: Bool = true) -> ChannelDetails {
        var channel = ChannelDetails.mock(isChannelReady: isChannelReady, outboundCapacityMsat: sendableSats * 1000)
        channel.channelId = id
        return channel
    }
}
