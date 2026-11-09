@testable import Bitkit
import LDKNode
import XCTest

final class MoveToSparkLateOutcomeTests: XCTestCase {
    func testLateSuccessOfTheInFlightMoveShowsItMovedWithItsFee() {
        let state = MoveToSparkState.inFlight(amountSats: 40000)
        XCTAssertTrue(MoveToSparkManager.showsInFlightMove(state, generation: 3, moveGeneration: 3))

        let emptied = ChannelDetails.mock(outboundCapacityMsat: 500_000)
        let done = MoveToSparkManager.doneState(amountSats: 40000, feeSats: 12, channels: [emptied])
        XCTAssertEqual(done, .done(amountSats: 40000, feeSats: 12, closeChannel: emptied, hasRest: false))
    }

    func testLateSuccessOfAPartialMoveOffersTheRest() {
        let channel = ChannelDetails.mock(outboundCapacityMsat: 50_000_000)
        let done = MoveToSparkManager.doneState(amountSats: 25000, feeSats: 7, channels: [channel])
        XCTAssertEqual(done, .done(amountSats: 25000, feeSats: 7, closeChannel: channel, hasRest: true))
    }

    func testLateOutcomeOfAnOlderMoveLeavesTheScreen() {
        XCTAssertFalse(MoveToSparkManager.showsInFlightMove(.inFlight(amountSats: 40000), generation: 4, moveGeneration: 3))
        XCTAssertFalse(MoveToSparkManager.showsInFlightMove(.quoting, generation: 3, moveGeneration: 3))
    }
}
