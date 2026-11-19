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
        let emptied = MoveToSparkMath.emptiedChannels(before: before, after: after, payments: [])
        XCTAssertEqual(emptied.map(\.channelId), ["a"], "A channel that could send less than the move minimum was closed")
    }

    func testAChannelClosesOnlyOnceItsReserveExplainsItsLimit() {
        func funded(sendableSats: UInt64, capacitySats: UInt64, feerate: UInt32 = 2500) -> ChannelDetails {
            var channel = channel("a", sendableSats: sendableSats, capacitySats: capacitySats)
            channel.isOutbound = true
            channel.feerateSatPer1000Weight = feerate
            return channel
        }
        // The move's settled HTLC still counts against the peer's in-flight cap: 5 002 sats of capacity, limit 0.
        XCTAssertTrue(MoveToSparkMath.mayHoldTheMoveHtlc(funded(sendableSats: 0, capacitySats: 5002)), "Closed on a held reading")
        // Once it clears the channel can send 1 332 sats, so it is no longer emptied.
        let before = [channel("a", sendableSats: 50000)]
        let cleared = funded(sendableSats: 1332, capacitySats: 5002)
        XCTAssertTrue(MoveToSparkMath.emptiedChannels(before: before, after: [cleared], payments: []).isEmpty)
        // A legacy reserve at 2 500 sat/kW is 4 480 sats: 5 342 of capacity sending 862 is what stays, so it closes.
        XCTAssertFalse(MoveToSparkMath.mayHoldTheMoveHtlc(funded(sendableSats: 862, capacitySats: 5342)))
        // A legacy channel at 253 sat/kW reserves 540 sats above dust: 1 400 of capacity sends 860.
        XCTAssertFalse(MoveToSparkMath.mayHoldTheMoveHtlc(funded(sendableSats: 860, capacitySats: 1400, feerate: 253)))
        XCTAssertTrue(MoveToSparkMath.mayHoldTheMoveHtlc(funded(sendableSats: 947, capacitySats: 1400, feerate: 253)))
        // An anchor reserve at 253 sat/kW is 371 sats.
        XCTAssertFalse(MoveToSparkMath.mayHoldTheMoveHtlc(funded(sendableSats: 629, capacitySats: 1000, feerate: 253)))
        // Capacity under the minimum rules the HTLC out; a channel the peer funded keeps no reserve on our side.
        XCTAssertFalse(MoveToSparkMath.mayHoldTheMoveHtlc(funded(sendableSats: 0, capacitySats: 900)))
        var peerFunded = funded(sendableSats: 0, capacitySats: 5002)
        peerFunded.isOutbound = false
        XCTAssertTrue(MoveToSparkMath.mayHoldTheMoveHtlc(peerFunded))
    }

    func testAReserveMatchClosesOnlyOnceItHoldsAcrossARecheck() {
        func funded(sendableSats: UInt64, capacitySats: UInt64) -> ChannelDetails {
            var channel = channel("a", sendableSats: sendableSats, capacitySats: capacitySats)
            channel.isOutbound = true
            channel.feerateSatPer1000Weight = 4000
            return channel
        }
        // 4 000 sat/kW: a capped 2-sat limit on 7 170 sats of capacity matches the 7 168-sat legacy reserve by chance.
        let capped = funded(sendableSats: 2, capacitySats: 7170)
        XCTAssertFalse(MoveToSparkMath.mayHoldTheMoveHtlc(capped))
        XCTAssertFalse(MoveToSparkMath.isEmptiedForGood(capped, previous: nil), "Closed on a first reading")
        // Once the HTLC clears the limit rises, so the next read no longer matches the one before.
        XCTAssertFalse(MoveToSparkMath.isEmptiedForGood(funded(sendableSats: 3500, capacitySats: 7170), previous: [capped]))
        // A reserve that holds across the recheck is what stays.
        XCTAssertTrue(MoveToSparkMath.isEmptiedForGood(capped, previous: [capped]))
        // Capacity under the minimum closes on the first read.
        XCTAssertTrue(MoveToSparkMath.isEmptiedForGood(funded(sendableSats: 0, capacitySats: 900), previous: nil))
    }

    func testAMoveLeavesChannelsItDidNotKnowOrThatAreNotOpen() {
        let before = [channel("a", sendableSats: 50000)]
        let after = [channel("a", sendableSats: 0, isChannelReady: false), channel("new", sendableSats: 0)]
        XCTAssertTrue(MoveToSparkMath.emptiedChannels(before: before, after: after, payments: []).isEmpty)
        XCTAssertTrue(MoveToSparkMath.emptiedChannels(before: before, after: nil, payments: []).isEmpty)
    }

    func testAMoveClosesNoChannelWhileAnotherPaymentIsInFlight() {
        let before = [channel("a", sendableSats: 50000)]
        let after = [channel("a", sendableSats: 0)]
        XCTAssertEqual(MoveToSparkMath.emptiedChannels(before: before, after: after, payments: [payment(.outbound, .succeeded)]).count, 1)
        XCTAssertEqual(MoveToSparkMath.emptiedChannels(before: before, after: after, payments: [payment(.inbound, .pending)]).count, 1)
        XCTAssertTrue(
            MoveToSparkMath.emptiedChannels(before: before, after: after, payments: [payment(.outbound, .pending)]).isEmpty,
            "A channel whose send limit an in-flight payment lowered was closed"
        )
        XCTAssertTrue(MoveToSparkMath.emptiedChannels(before: before, after: after, payments: nil).isEmpty)
        // An unconfirmed on-chain send from savings holds no HTLC, so the emptied channel still closes.
        let onchainSend = payment(.outbound, .pending, kind: .onchain(txid: "txid", status: .unconfirmed))
        XCTAssertEqual(MoveToSparkMath.emptiedChannels(before: before, after: after, payments: [onchainSend]).count, 1)
    }

    func testAPaymentInFlightAroundTheChannelsReadHoldsTheCloseBack() {
        let before = [channel("a", sendableSats: 50000)]
        let after = [channel("a", sendableSats: 0)]
        let settled = [payment(.outbound, .succeeded)]
        let inFlight = [payment(.outbound, .pending)]
        func emptied(_ first: [PaymentDetails]?, _ second: [PaymentDetails]?) -> Int {
            MoveToSparkMath.emptiedChannels(
                before: before,
                after: after,
                payments: MoveToSparkMath.paymentsAround(moveStart: first, channelsRead: first, second, isMovePayment: { _ in false })
            ).count
        }
        XCTAssertEqual(emptied(settled, settled), 1)
        // A payment that failed after the first read, or started before the second, lowered the limit read in between.
        XCTAssertEqual(emptied(inFlight, settled), 0)
        XCTAssertEqual(emptied(settled, inFlight), 0)
        XCTAssertEqual(emptied(settled, nil), 0)
        // A payment that started after the first read and failed before the second was in flight in between.
        XCTAssertEqual(emptied(settled, settled + [payment(.outbound, .failed)]), 0)
        // A failed payment retried under its id and failing again between the reads shows only as a later update.
        let failed = payment(.outbound, .failed, id: "retried", updatedAt: 1)
        XCTAssertEqual(emptied([failed], [failed]), 1)
        XCTAssertEqual(emptied([failed], [payment(.outbound, .failed, id: "retried", updatedAt: 2)]), 0)
        XCTAssertEqual(emptied([failed], [payment(.outbound, .succeeded, id: "retried", updatedAt: 1)]), 0)
        // An on-chain send or an incoming payment changing meanwhile holds no outbound HTLC.
        XCTAssertEqual(emptied(settled, settled + [payment(.inbound, .succeeded)]), 1)
        XCTAssertEqual(emptied(settled, settled + [payment(.outbound, .pending, kind: .onchain(txid: "t", status: .unconfirmed))]), 1)
    }

    func testAnotherSendDuringTheMoveHoldsTheCloseBack() {
        let before = [channel("a", sendableSats: 50000), channel("b", sendableSats: 20000)]
        let after = [channel("a", sendableSats: 0), channel("b", sendableSats: 0)]
        let start = [payment(.outbound, .succeeded, id: "old")]
        let move = payment(.outbound, .succeeded, id: "move")
        func emptied(_ reads: [PaymentDetails]) -> Int {
            MoveToSparkMath.emptiedChannels(
                before: before,
                after: after,
                payments: MoveToSparkMath.paymentsAround(moveStart: start, channelsRead: reads, reads, isMovePayment: { $0 == "move" })
            ).count
        }
        // The move's own payment settling is what empties its channels.
        XCTAssertEqual(emptied(start + [move]), 2)
        // A send the user made meanwhile, from another channel, settled before the move did.
        XCTAssertEqual(emptied(start + [move, payment(.outbound, .succeeded, id: "other")]), 0, "A channel another send emptied was closed")
        XCTAssertTrue(
            MoveToSparkMath.paymentsAround(moveStart: nil, channelsRead: start, start, isMovePayment: { _ in false }) == nil,
            "An unreadable start counted as nothing sent"
        )
    }

    private func payment(
        _ direction: PaymentDirection,
        _ status: PaymentStatus,
        kind: PaymentKind = .spontaneous(hash: "hash", preimage: nil),
        id: String = UUID().uuidString,
        updatedAt: UInt64 = 0
    ) -> PaymentDetails {
        PaymentDetails(
            id: id, kind: kind,
            amountMsat: 1_000_000, feePaidMsat: nil, direction: direction, status: status, latestUpdateTimestamp: updatedAt
        )
    }

    private func channel(_ id: String, sendableSats: UInt64, capacitySats: UInt64? = nil, isChannelReady: Bool = true) -> ChannelDetails {
        var channel = ChannelDetails.mock(isChannelReady: isChannelReady, outboundCapacityMsat: (capacitySats ?? sendableSats) * 1000)
        channel.nextOutboundHtlcLimitMsat = sendableSats * 1000
        channel.channelId = id
        return channel
    }
}
