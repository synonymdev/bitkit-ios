@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

@MainActor
final class MoveToSparkQuoteTests: XCTestCase {
    private final class FakeServices: MoveToSparkServices, @unchecked Sendable {
        var isSparkUsable = true
        var estimate: (UInt64) throws -> UInt64 = { _ in 30 }
        private(set) var quotedAmounts: [UInt64] = []

        func receiveInvoice(description _: String, expirySecs _: UInt32) async throws -> String {
            "lnbcrt1move"
        }

        func estimateChannelFee(bolt11 _: String, amountSats: UInt64) async throws -> UInt64 {
            quotedAmounts.append(amountSats)
            return try estimate(amountSats)
        }

        var spark = SparkSendState(isReady: true, isExiting: false, balanceSats: 0)

        func estimateSparkFee(bolt11 _: String, amountSats _: UInt64) async throws -> UInt64 {
            0
        }

        func refreshSpark() async {}
    }

    private struct OtherError: Error {}

    /// Channels that can send 100,000 sats.
    private let channels = [ChannelDetails.mock(outboundCapacityMsat: 100_000_000)]

    /// The fee a part may pay for the fake 30-sat estimate under `limitSats`.
    private func cappedFee(_ limitSats: UInt64) -> UInt64 {
        MoveToSparkMath.cappedFeeSats(estimateSats: 30, limitSats: limitSats)
    }

    func testQuoteGrowsToFitTheRealFee() async throws {
        let services = FakeServices()
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        let amountSats = MoveToSparkMath.amountAfterCappedFee(limitSats: 100_000, estimateSats: 30)
        XCTAssertEqual(amountSats, 99890)
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: amountSats, feeSats: cappedFee(100_000)))
        XCTAssertEqual(services.quotedAmounts, [99498, amountSats])
    }

    func testQuoteFallsBackToTheLastFittingAmount() async throws {
        let services = FakeServices()
        services.estimate = { amount in
            guard amount == 99498 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 99498, feeSats: cappedFee(100_000)))
    }

    func testABalanceThatDoesNotRouteAtOnceShowsTheFeeOfEveryPart() async throws {
        let services = FakeServices()
        services.estimate = { amount in
            guard amount <= 30000 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        // Halved twice to a part that routes, then parts no larger until less than the minimum is left: four parts, each
        // under a limit of at least 25,048 sats, where twice the estimate and 50 is the cap.
        XCTAssertEqual(cappedFee(25048), 110)
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 24874, feeSats: 4 * 110, firstFeeSats: 110))
    }

    func testAPeerHtlcCapSizesThePartsNotTheTotal() async throws {
        let capped = [ChannelDetails.mock(outboundCapacityMsat: 100_000_000, nextOutboundHtlcLimitMsat: 30_032_000)]
        let quote = try await MoveToSparkManager(services: FakeServices()).makeQuote(channels: capped)
        XCTAssertEqual(quote.amountSats, MoveToSparkMath.amountAfterCappedFee(limitSats: 30032, estimateSats: 30))
        // Three parts under the 30,032-sat cap and a fourth under the 6,234 sats the 96,330 the channel holds leave.
        XCTAssertEqual(quote.feeSats, 3 * cappedFee(30032) + cappedFee(6234), "Every part of the balance the channels hold is priced")
    }

    func testAFundedChannelsCommitmentFeeIsNotPricedAsAPart() async throws {
        let capacityMsat: UInt64 = 100_000_000
        let limitMsat = UInt64(MoveToSparkMath.clearedLimitMsat(capacityMsat: Int64(capacityMsat), feerate: 2500, isLegacy: true))
        let funded = [ChannelDetails.mock(outboundCapacityMsat: capacityMsat, nextOutboundHtlcLimitMsat: limitMsat)]
        XCTAssertTrue(funded[0].isOutbound)
        let quote = try await MoveToSparkManager(services: FakeServices()).makeQuote(channels: funded)
        XCTAssertEqual(quote.feeSats, cappedFee(limitMsat / 1000), "One part: the commitment fee the channel holds back is not balance to move")
    }

    func testALegacyFundedChannelPricesTheBelowDustPartItLeaves() async throws {
        let capacityMsat: UInt64 = 100_000_000
        let limitMsat = UInt64(MoveToSparkMath.clearedLimitMsat(capacityMsat: Int64(capacityMsat), feerate: 4000, isLegacy: true))
        let funded = [ChannelDetails.mock(
            outboundCapacityMsat: capacityMsat,
            nextOutboundHtlcLimitMsat: limitMsat,
            feerateSatPer1000Weight: 4000
        )]
        let quote = try await MoveToSparkManager(services: FakeServices()).makeQuote(channels: funded)
        let restSats = MoveToSparkMath.outboundSats(channels: funded) - limitMsat / 1000
        XCTAssertEqual(restSats, 1376)
        XCTAssertEqual(
            quote.feeSats,
            cappedFee(limitMsat / 1000) + cappedFee(restSats),
            "The below-dust part the legacy reserve leaves is priced too"
        )
    }

    func testABelowDustRestUnderThePeersHtlcMinimumIsNotPriced() async throws {
        let capacityMsat: UInt64 = 100_000_000
        let limitMsat = UInt64(MoveToSparkMath.clearedLimitMsat(capacityMsat: Int64(capacityMsat), feerate: 4000, isLegacy: true))
        let funded = [ChannelDetails.mock(
            outboundCapacityMsat: capacityMsat,
            nextOutboundHtlcLimitMsat: limitMsat,
            feerateSatPer1000Weight: 4000,
            nextOutboundHtlcMinimumMsat: 2_000_000
        )]
        let quote = try await MoveToSparkManager(services: FakeServices()).makeQuote(channels: funded)
        XCTAssertEqual(quote.feeSats, cappedFee(limitMsat / 1000), "A rest under the peer's HTLC minimum cannot be sent, so it is no part")
    }

    func testALoneRestTooSmallForTheFeeGuessIsNotPriced() {
        let capacityMsat: Int64 = 100_000_000
        let limitMsat = MoveToSparkMath.clearedLimitMsat(capacityMsat: capacityMsat, feerate: 2904, isLegacy: true)
        let restSats = MoveToSparkMath.clearedLimitMsat(capacityMsat: capacityMsat - limitMsat, feerate: 2904, isLegacy: true) / 1000
        XCTAssertEqual(restSats, 1000)
        let funded = [ChannelDetails.mock(
            outboundCapacityMsat: UInt64(capacityMsat),
            nextOutboundHtlcLimitMsat: UInt64(limitMsat),
            feerateSatPer1000Weight: 2904
        )]
        XCTAssertEqual(
            MoveToSparkMath.outboundSats(channels: funded),
            UInt64(limitMsat / 1000),
            "A 1,000-sat rest leaves no part once the fee guess is reserved, yet was priced"
        )
    }

    func testRestsTooSmallAloneArePricedTogether() {
        let capacityMsat: Int64 = 100_000_000
        let limitMsat = MoveToSparkMath.clearedLimitMsat(capacityMsat: capacityMsat, feerate: 2500, isLegacy: true)
        let restSats = UInt64(MoveToSparkMath.clearedLimitMsat(capacityMsat: capacityMsat - limitMsat, feerate: 2500, isLegacy: true) / 1000)
        XCTAssertFalse(MoveToSparkMath.hasMovableBalance(limitSats: restSats))
        XCTAssertTrue(MoveToSparkMath.hasMovableBalance(limitSats: 2 * restSats))
        let funded = (0 ..< 2).map { index in
            var channel = ChannelDetails.mock(outboundCapacityMsat: UInt64(capacityMsat), nextOutboundHtlcLimitMsat: UInt64(limitMsat))
            channel.channelId = "channel\(index)"
            return channel
        }
        XCTAssertEqual(
            MoveToSparkMath.outboundSats(channels: funded),
            2 * (UInt64(limitMsat / 1000) + restSats),
            "Two rests that together make a part were left out"
        )
    }

    func testAnAnchorChannelsBelowDustRestUnderTheMinimumIsNotPriced() {
        let capacityMsat: UInt64 = 100_000_000
        let limitMsat = UInt64(MoveToSparkMath.clearedLimitMsat(capacityMsat: Int64(capacityMsat), feerate: 10000, isLegacy: false))
        let funded = [ChannelDetails.mock(
            outboundCapacityMsat: capacityMsat,
            nextOutboundHtlcLimitMsat: limitMsat,
            feerateSatPer1000Weight: 10000
        )]
        let channels = MoveToSparkMath.outboundSats(channels: funded)
        XCTAssertEqual(channels, limitMsat / 1000, "An anchor rest stays under the move minimum")
    }

    func testAFundedChannelWithAPeerHtlcCapPricesItsLastPart() async throws {
        let capped = [ChannelDetails.mock(outboundCapacityMsat: 65_000_000, nextOutboundHtlcLimitMsat: 30_032_000)]
        let quote = try await MoveToSparkManager(services: FakeServices()).makeQuote(channels: capped)
        // Two parts under the 30,032-sat cap, then the 1,266 sats left of the 61,330 the anchor commitment leaves.
        XCTAssertEqual(quote.feeSats, 2 * cappedFee(30032) + cappedFee(1266), "The anchor commitment's smaller reserve leaves a third part to price")
    }

    func testNoPartThatRoutesIsNoRoute() async {
        let services = FakeServices()
        services.estimate = { _ in throw NodeError.RouteNotFound(message: "no route") }
        await assertQuoteThrows(services, expected: .noRoute)
        XCTAssertEqual(services.quotedAmounts.last.map { $0 < 2 * MoveToSparkMath.minMoveSats }, true, "Halving stopped above the minimum")
    }

    func testAFeeThatNeverFitsIsHalvedUntilNoPartIsLeft() async {
        let services = FakeServices()
        services.estimate = { _ in 100_000 }
        await assertQuoteThrows(services, expected: .noRoute)
        XCTAssertEqual(Array(services.quotedAmounts.prefix(3)), [99498, 49749, 24874])
    }

    func testAPlanStopsAtTheMostParts() async throws {
        let services = FakeServices()
        services.estimate = { amount in
            guard amount <= 5000 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        XCTAssertEqual(quote.feeSats, UInt64(MoveToSparkMath.maxParts) * cappedFee(100_000), "The fee covers only the parts a swipe pays")
        XCTAssertEqual(quote.firstFeeSats, cappedFee(100_000))
    }

    // MARK: - Paying the parts

    /// Pays like the channels would: `routes` is the largest amount that routes, each paid part leaves the channels.
    private final class FakeChannels {
        var outboundSats: UInt64
        /// A peer's HTLC cap, which keeps the next-HTLC limit flat while the channels hold more.
        var htlcCapSats: UInt64 = .max
        var movableSats: UInt64 {
            min(outboundSats, htlcCapSats)
        }

        var routes: UInt64 = .max
        var paidFee: UInt64 = 30
        var failAfter: Int?
        var inFlightAt: Int?
        private(set) var paid: [(bolt11: String, amountSats: UInt64, feeCapMsat: UInt64)] = []

        init(movableSats: UInt64) {
            outboundSats = movableSats
        }

        func quotePart(limitSats: UInt64, wantedSats: UInt64) -> MoveToSparkPart? {
            let amount = min(wantedSats, limitSats - 32, routes)
            return amount >= MoveToSparkMath.minMoveSats ? MoveToSparkPart(amountSats: amount, feeSats: 32) : nil
        }

        /// Returns the fee paid in msat.
        func pay(_ bolt11: String, _ amountSats: UInt64, _ feeCapMsat: UInt64) throws -> UInt64? {
            if let failAfter, paid.count >= failAfter {
                throw OtherError()
            }
            paid.append((bolt11, amountSats, feeCapMsat))
            if paid.count == inFlightAt {
                return nil
            }
            outboundSats -= amountSats + paidFee
            return paidFee * 1000
        }

        func run(_ quote: MoveToSparkQuote) async throws -> MoveToSparkPartsOutcome {
            try await MoveToSparkManager.payParts(
                quote,
                movableSats: { self.movableSats },
                outboundSats: { self.outboundSats },
                newInvoice: { "lnbcrt1next" },
                quotePart: { self.quotePart(limitSats: $1, wantedSats: $2) },
                pay: { bolt11, amount, cap, _, _ in try self.pay(bolt11, amount, cap) }
            )
        }
    }

    private let plan = MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 128, firstFeeSats: 32)

    func testTheWholeBalanceMovesInPartsUnderTheFeeShown() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        let outcome = try await channels.run(plan)
        XCTAssertEqual(channels.paid.map(\.amountSats), [30000, 30000, 30000, 9878])
        XCTAssertEqual(channels.paid.map(\.bolt11), ["lnbcrt1first", "lnbcrt1next", "lnbcrt1next", "lnbcrt1next"])
        XCTAssertEqual(
            channels.paid.map(\.feeCapMsat),
            [128_000, 98000, 68000, 38000],
            "A part may spend only what is left of the fee shown"
        )
        XCTAssertEqual(outcome, .settled(movedSats: 99878, feeSats: 120))
    }

    func testASwipePaysAtMostTheMostParts() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 5000
        let outcome = try await channels.run(MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 5000, feeSats: 1000, firstFeeSats: 32))
        XCTAssertEqual(channels.paid.count, MoveToSparkMath.maxParts)
        XCTAssertEqual(outcome, .settled(movedSats: UInt64(MoveToSparkMath.maxParts) * 5000, feeSats: UInt64(MoveToSparkMath.maxParts) * 30))
    }

    func testAPartQuotedAboveTheFeeLeftStopsTheMoveToShowTheNewFee() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        do {
            _ = try await channels.run(MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 70, firstFeeSats: 32))
            XCTFail("Expected the fee to rise")
        } catch let MoveToSparkError.feeRose(movedSats, _) {
            XCTAssertEqual(movedSats, 60000)
            XCTAssertEqual(channels.paid.count, 2, "A part was paid above the fee shown")
        }
    }

    func testAFeeRoundedDownStillCountsInFullAgainstTheFeeShown() async {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        var caps: [UInt64] = []
        _ = try? await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 64, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { _, amount, cap, _, _ in
                caps.append(cap)
                channels.outboundSats -= amount + 32
                return 31900
            }
        )
        XCTAssertEqual(caps, [64000, 32100], "The next part could spend the 900 msat the first one paid above 31 sats")
    }

    func testASpentFeeWithBalanceLeftShowsTheNewFee() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        channels.paidFee = 32
        do {
            _ = try await channels.run(MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 64, firstFeeSats: 32))
            XCTFail("Expected the fee to rise for what is left")
        } catch let MoveToSparkError.feeRose(movedSats, _) {
            XCTAssertEqual(movedSats, 60000)
        }
    }

    func testAPartThatDoesNotSendIsHalved() async throws {
        let channels = FakeChannels(movableSats: 40000)
        var tried: [UInt64] = []
        let outcome = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 39968, feeSats: 200, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { bolt11, amount, cap, _, _ in
                tried.append(amount)
                guard amount <= 10000 else { throw NodeError.RouteNotFound(message: "no route") }
                return try channels.pay(bolt11, amount, cap)
            }
        )
        XCTAssertEqual(Array(tried.prefix(3)), [39968, 19984, 9992])
        XCTAssertEqual(outcome, .settled(movedSats: 39878, feeSats: 120))
    }

    func testARouteThatShrinksDuringTheMoveLowersTheLaterParts() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        var wanted: [UInt64] = []
        _ = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 1000, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { _, limitSats, wantedSats in
                wanted.append(wantedSats)
                guard wanted.count == 1, var part = channels.quotePart(limitSats: limitSats, wantedSats: 15000) else {
                    return channels.quotePart(limitSats: limitSats, wantedSats: wantedSats)
                }
                // The route now carries only half the target.
                part.routeHalvedToSats = 15000
                return part
            },
            pay: { bolt11, amount, cap, _, _ in try channels.pay(bolt11, amount, cap) }
        )
        XCTAssertEqual(Array(wanted.prefix(2)), [30000, 15000], "A later part quoted a size that no longer routed")
    }

    func testAQuoteHalvedByItsRouteCarriesTheSizeThatRouted() async throws {
        let services = FakeServices()
        services.estimate = { amountSats in
            guard amountSats <= 20000 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let manager = MoveToSparkManager(services: services)

        let halvedPart = try await manager.quotePart(invoice: "lnbcrt1move", limitSats: 100_000, wantedSats: 40000)
        let routedPart = try await manager.quotePart(invoice: "lnbcrt1move", limitSats: 100_000, wantedSats: 15000)
        let halved = try XCTUnwrap(halvedPart)
        let routed = try XCTUnwrap(routedPart)

        XCTAssertNotNil(halved.routeHalvedToSats)
        XCTAssertLessThanOrEqual(halved.amountSats, halved.routeHalvedToSats ?? 0)
        XCTAssertNil(routed.routeHalvedToSats, "A part that routed at its size lowered the target")
    }

    func testAPartALowSendLimitCappedSmallLeavesTheNextPartItsSize() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        var wanted: [UInt64] = []
        var reads = 0
        _ = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 1000, firstFeeSats: 32),
            movableSats: {
                reads += 1
                // The read after the first part sees a send limit held down below the target.
                return reads == 2 ? 25000 : channels.movableSats
            },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { _, limitSats, wantedSats in
                wanted.append(wantedSats)
                // Under the held-down limit only a small part fits its fee.
                return channels.quotePart(limitSats: limitSats, wantedSats: wanted.count == 1 ? 12000 : wantedSats)
            },
            pay: { bolt11, amount, cap, _, _ in try channels.pay(bolt11, amount, cap) }
        )
        XCTAssertEqual(Array(wanted.prefix(2)), [25000, 30000], "A part capped small kept the parts after it small")
        XCTAssertEqual(Array(channels.paid.map(\.amountSats).prefix(3)), [30000, 12000, 30000])
    }

    func testRetriedPartsAreDroppedOnceALaterPartSettles() async throws {
        let channels = FakeChannels(movableSats: 40000)
        var invoices = 0
        var dropped: [[String]] = []
        _ = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 39968, feeSats: 200, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: {
                invoices += 1
                return "lnbcrt1next\(invoices)"
            },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { bolt11, amount, cap, _, _ in
                guard amount <= 10000 else { throw NodeError.RouteNotFound(message: "no route") }
                return try channels.pay(bolt11, amount, cap)
            },
            onRetriedPartsSettled: { dropped.append($0) }
        )
        XCTAssertEqual(dropped, [["lnbcrt1first", "lnbcrt1next1"]], "The failed sends of retried parts stayed in Activity")
    }

    func testAPartInFlightAfterRetriedPartsGetsThemForItsLateOutcome() async throws {
        let channels = FakeChannels(movableSats: 40000)
        var invoices = 0
        var sending: [String: [String]] = [:]
        var dropped: [[String]] = []
        let outcome = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 39968, feeSats: 200, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: {
                invoices += 1
                return "lnbcrt1next\(invoices)"
            },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { _, amount, _, _, _ in
                guard amount <= 10000 else { throw NodeError.RouteNotFound(message: "no route") }
                return nil
            },
            onSendingAfterRetries: { sending[$0] = $1 },
            onRetriedPartsSettled: { dropped.append($0) }
        )
        XCTAssertEqual(outcome, .inFlight(movedSats: 0, feeSats: 0, partSats: 9992))
        XCTAssertEqual(sending["lnbcrt1next2"], ["lnbcrt1first", "lnbcrt1next1"], "A part settling late could not drop the retried parts")
        XCTAssertTrue(dropped.isEmpty, "Retried parts were dropped before the part after them settled")
    }

    func testRetriedPartsKeepTheirFailedRowsWhenNoLaterPartSettles() async {
        let channels = FakeChannels(movableSats: 40000)
        var dropped: [[String]] = []
        _ = try? await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 39968, feeSats: 200, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { _, _, _, _, _ in throw NodeError.RouteNotFound(message: "no route") },
            onRetriedPartsSettled: { dropped.append($0) }
        )
        XCTAssertTrue(dropped.isEmpty, "A failed part was dropped though nothing settled after it")
    }

    func testALimitAnHtlcHeldDownDoesNotShrinkTheLaterParts() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        var wanted: [UInt64] = []
        var reads = 0
        _ = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 1000, firstFeeSats: 32),
            movableSats: {
                reads += 1
                // The read after the first part sees its HTLC still holding the send limit down.
                return reads == 2 ? 20000 : channels.movableSats
            },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { _, limitSats, wantedSats in
                wanted.append(wantedSats)
                return channels.quotePart(limitSats: limitSats, wantedSats: wantedSats)
            },
            pay: { bolt11, amount, cap, _, _ in try channels.pay(bolt11, amount, cap) }
        )
        XCTAssertEqual(Array(wanted.prefix(2)), [20000, 30000], "A part sized by a held-down limit shrank the ones after it")
    }

    func testAPeerHtlcCapThatKeepsTheLimitFlatDoesNotStopTheMove() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.htlcCapSats = 30032
        channels.routes = 30000
        let outcome = try await channels.run(plan)
        XCTAssertEqual(channels.paid.map(\.amountSats), [30000, 30000, 30000, 9878])
        XCTAssertEqual(outcome, .settled(movedSats: 99878, feeSats: 120))
    }

    func testAPartThatDoesNotRouteBelowTheMinimumShowsANewFeeAboveTheFeeLeft() async throws {
        let channels = FakeChannels(movableSats: 40000)
        do {
            _ = try await payUnroutable(channels, freshFeeSats: 300)
            XCTFail("Expected the modal to quote the rest again")
        } catch let MoveToSparkError.feeRose(movedSats, _) {
            XCTAssertEqual(movedSats, 0)
        }
    }

    func testAPartThatDoesNotRouteBelowTheMinimumWithinTheFeeLeftFailsTheSend() async {
        let channels = FakeChannels(movableSats: 40000)
        do {
            _ = try await payUnroutable(channels, freshFeeSats: 32)
            XCTFail("Expected the send error")
        } catch {
            XCTAssertTrue(MoveToSparkManager.isNoRoute(error))
        }
    }

    /// Pays a 1,500-sat first part that never routes, under a 200-sat fee, where a fresh quote prices `freshFeeSats`.
    private func payUnroutable(_ channels: FakeChannels, freshFeeSats: UInt64) async throws -> MoveToSparkPartsOutcome {
        try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 1500, feeSats: 200, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { _, _, _ in MoveToSparkPart(amountSats: 1500, feeSats: freshFeeSats) },
            pay: { _, _, _, _, _ in throw NodeError.RouteNotFound(message: "no route") }
        )
    }

    func testAMoveNoLongerWantedStopsBeforeItsNextPart() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        var invoices = 0
        let outcome = try await MoveToSparkManager.payParts(
            plan,
            isWanted: { channels.paid.isEmpty },
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: {
                invoices += 1
                return "lnbcrt1next"
            },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { bolt11, amount, cap, _, _ in try channels.pay(bolt11, amount, cap) }
        )
        XCTAssertEqual(invoices, 0, "A wiped wallet or an exiting Spark got another part")
        XCTAssertEqual(outcome, .settled(movedSats: 30000, feeSats: 30))
    }

    func testALaterPartGetsThePaidFeeInMsat() async {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        var paidFees: [UInt64] = []
        _ = try? await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 128, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            outboundSats: { channels.outboundSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { _, amount, _, _, feeMsat in
                paidFees.append(feeMsat)
                channels.outboundSats -= amount + 32
                return 31900
            }
        )
        XCTAssertEqual(Array(paidFees.prefix(3)), [0, 31900, 63800], "A late outcome would round each part's fee apart")
    }

    func testAFailureAfterAPartMovedStopsWithWhatMoved() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        channels.failAfter = 1
        let outcome = try await channels.run(plan)
        XCTAssertEqual(outcome, .settled(movedSats: 30000, feeSats: 30))
    }

    func testAFirstPartThatFailsMovesNothing() async {
        let channels = FakeChannels(movableSats: 30000)
        channels.failAfter = 0
        do {
            _ = try await channels.run(MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 29968, feeSats: 32))
            XCTFail("Expected the failure")
        } catch {
            XCTAssertTrue(error is OtherError)
        }
    }

    func testAPartInFlightEndsTheMoveWithWhatMovedBeforeIt() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        channels.inFlightAt = 2
        let outcome = try await channels.run(plan)
        XCTAssertEqual(outcome, .inFlight(movedSats: 30000, feeSats: 30, partSats: 30000))
    }

    func testAPartThatLeavesTheBalanceWhereItWasStopsTheMove() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        var calls = 0
        let outcome = try await MoveToSparkManager.payParts(
            plan,
            movableSats: { 100_000 },
            outboundSats: { 100_000 },
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { _, _, _, _, _ in
                calls += 1
                return 0
            }
        )
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome, .settled(movedSats: 30000, feeSats: 0))
    }

    func testOtherEstimateErrorsAreRethrown() async {
        let services = FakeServices()
        services.estimate = { _ in throw OtherError() }
        do {
            _ = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is OtherError)
        }
    }

    func testNothingToMoveWithoutChannels() async {
        await assertQuoteThrows(FakeServices(), channels: [], expected: .nothingToMove)
    }

    func testSparkUnavailableStopsTheQuote() async {
        let services = FakeServices()
        services.isSparkUsable = false
        await assertQuoteThrows(services, expected: .sparkUnavailable)
        XCTAssertTrue(services.quotedAmounts.isEmpty)
    }

    private func assertQuoteThrows(
        _ services: FakeServices,
        channels: [ChannelDetails]? = nil,
        expected: MoveToSparkError,
        line: UInt = #line
    ) async {
        do {
            _ = try await MoveToSparkManager(services: services).makeQuote(channels: channels ?? self.channels)
            XCTFail("Expected \(expected)", line: line)
        } catch let error as MoveToSparkError {
            switch (error, expected) {
            case (.noRoute, .noRoute), (.nothingToMove, .nothingToMove), (.sparkUnavailable, .sparkUnavailable): break
            default: XCTFail("Expected \(expected), got \(error)", line: line)
            }
        } catch {
            XCTFail("Expected \(expected), got \(error)", line: line)
        }
    }
}

@MainActor
final class MoveToSparkPaymentsTests: XCTestCase {
    private var suiteName = ""
    private var savedDefaults = UserDefaults.standard

    override func setUp() async throws {
        suiteName = "MoveToSparkPaymentsTests-\(UUID().uuidString)"
        savedDefaults = MoveToSparkPayments.defaults
        MoveToSparkPayments.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        MoveToSparkPayments.defaults.removePersistentDomain(forName: suiteName)
        MoveToSparkPayments.defaults = savedDefaults
    }

    func testHashSurvivesARelaunch() throws {
        MoveToSparkPayments.insert("ABCD")
        // A relaunch reads the same store anew.
        MoveToSparkPayments.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertTrue(MoveToSparkPayments.contains("abcd"))
        XCTAssertFalse(MoveToSparkPayments.contains("ef01"))
        XCTAssertFalse(MoveToSparkPayments.contains(nil))
    }

    func testAnOldMoveIsStillKnown() {
        MoveToSparkPayments.insert("abcd", now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(MoveToSparkPayments.contains("abcd"))
    }

    func testOnlyAMovesSendIsAMoveToSpark() {
        MoveToSparkPayments.insert("abcd")
        XCTAssertTrue(activity(id: "abcd", type: .sent, message: "").isMoveToSpark)
        XCTAssertFalse(activity(id: "ef01", type: .sent, message: MoveToSparkMath.invoiceDescription).isMoveToSpark)
        XCTAssertFalse(activity(id: "abcd", type: .received, message: "").isMoveToSpark)
    }

    private func activity(id: String, type: BitkitCore.PaymentType, message: String) -> LightningActivity {
        LightningActivity(
            walletId: WalletScope.default, id: id, txType: type, status: .succeeded, value: 1000, fee: 1,
            invoice: "lnbcrt1", message: message, timestamp: 1, preimage: nil, contact: nil,
            createdAt: 1, updatedAt: 1, seenAt: nil
        )
    }

    func testRestoredHashesAreKnownAndBackedUpSorted() throws {
        MoveToSparkPayments.insert("ef01")
        MoveToSparkPayments.restore(["ABCD", "ef01"])
        XCTAssertTrue(MoveToSparkPayments.contains("abcd"))
        XCTAssertEqual(MoveToSparkPayments.backupSnapshot(), ["abcd", "ef01"])

        let json = #"{"version":1,"createdAt":1,"tagMetadata":[],"cache":{"hasSeenContactsIntro":true},"moveToSparkPaymentHashes":["abcd"]}"#
        XCTAssertEqual(try JSONDecoder().decode(MetadataBackupV1.self, from: Data(json.utf8)).moveToSparkPaymentHashes, ["abcd"])
        let older = #"{"version":1,"createdAt":1,"tagMetadata":[],"cache":{"hasSeenContactsIntro":true}}"#
        XCTAssertNil(try JSONDecoder().decode(MetadataBackupV1.self, from: Data(older.utf8)).moveToSparkPaymentHashes)
    }

    func testWipeForgetsEveryHash() {
        MoveToSparkPayments.insert("abcd")
        MoveToSparkPayments.dropFailed(["abcd"])
        MoveToSparkPayments.retried.set(["abcd"], before: "ef01")
        MoveToSparkPayments.removeAll()
        XCTAssertFalse(MoveToSparkPayments.contains("abcd"))
        XCTAssertTrue(MoveToSparkPayments.droppedBackupSnapshot().isEmpty)
        XCTAssertNil(MoveToSparkPayments.retried.take(before: "ef01"))
    }

    func testRetriedPartsSurviveARelaunchUntilTakenOnce() throws {
        MoveToSparkPayments.retried.set(["ABCD"], before: "EF01")
        // A relaunch reads the same store anew.
        MoveToSparkPayments.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(MoveToSparkPayments.retried.take(before: "ef01"), ["abcd"])
        XCTAssertNil(MoveToSparkPayments.retried.take(before: "ef01"), "Two callers dropped the same retried parts")
    }

    func testARetriedMovePartsFailureIsDroppedAndBackedUp() throws {
        MoveToSparkPayments.dropFailed(["ABCD"])
        XCTAssertTrue(MoveToSparkPayments.dropped.contains("abcd"))
        XCTAssertFalse(MoveToSparkPayments.dropped.contains("ef01"))
        MoveToSparkPayments.restoreDropped(["ef01", "abcd"])
        XCTAssertEqual(MoveToSparkPayments.droppedBackupSnapshot(), ["abcd", "ef01"])
        let json = #"{"version":1,"createdAt":1,"tagMetadata":[],"cache":{"hasSeenContactsIntro":true},"moveToSparkDroppedPaymentHashes":["abcd"]}"#
        XCTAssertEqual(try JSONDecoder().decode(MetadataBackupV1.self, from: Data(json.utf8)).moveToSparkDroppedPaymentHashes, ["abcd"])
    }
}
