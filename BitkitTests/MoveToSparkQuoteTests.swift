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

    func testQuoteGrowsToFitTheRealFee() async throws {
        let services = FakeServices()
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 99968, feeSats: 32))
        XCTAssertEqual(services.quotedAmounts, [99498, 99968])
    }

    func testQuoteFallsBackToTheLastFittingAmount() async throws {
        let services = FakeServices()
        services.estimate = { amount in
            guard amount == 99498 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 99498, feeSats: 32))
    }

    func testABalanceThatDoesNotRouteAtOnceShowsTheFeeOfEveryPart() async throws {
        let services = FakeServices()
        services.estimate = { amount in
            guard amount <= 30000 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels)
        // Halved twice to a part that routes, then parts no larger until less than the minimum is left: four parts.
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 24874, feeSats: 128, firstFeeSats: 32))
        XCTAssertFalse(quote.isSinglePart)
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

    // MARK: - Paying the parts

    /// Pays like the channels would: `routes` is the largest amount that routes, each paid part leaves the channels.
    private final class FakeChannels {
        var movableSats: UInt64
        var routes: UInt64 = .max
        var paidFee: UInt64 = 30
        var failAfter: Int?
        var inFlightAt: Int?
        private(set) var paid: [(bolt11: String, part: MoveToSparkPart)] = []

        init(movableSats: UInt64) {
            self.movableSats = movableSats
        }

        func quotePart(limitSats: UInt64, wantedSats: UInt64) -> MoveToSparkPart? {
            let amount = min(wantedSats, limitSats - 32, routes)
            return amount >= MoveToSparkMath.minMoveSats ? MoveToSparkPart(amountSats: amount, feeSats: 32) : nil
        }

        /// `part.feeSats` is the fee cap the move paid it under.
        func pay(_ bolt11: String, _ part: MoveToSparkPart) throws -> UInt64? {
            if let failAfter, paid.count >= failAfter {
                throw OtherError()
            }
            paid.append((bolt11, part))
            if paid.count == inFlightAt {
                return nil
            }
            movableSats -= part.amountSats + paidFee
            return paidFee
        }

        func run(_ quote: MoveToSparkQuote) async throws -> MoveToSparkPartsOutcome {
            try await MoveToSparkManager.payParts(
                quote,
                movableSats: { self.movableSats },
                newInvoice: { "lnbcrt1next" },
                quotePart: { self.quotePart(limitSats: $1, wantedSats: $2) },
                pay: { bolt11, part, _, _ in try self.pay(bolt11, part) }
            )
        }
    }

    private let plan = MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 128, firstFeeSats: 32)

    func testTheWholeBalanceMovesInPartsUnderTheFeeShown() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        let outcome = try await channels.run(plan)
        XCTAssertEqual(channels.paid.map(\.part.amountSats), [30000, 30000, 30000, 9878])
        XCTAssertEqual(channels.paid.map(\.bolt11), ["lnbcrt1first", "lnbcrt1next", "lnbcrt1next", "lnbcrt1next"])
        XCTAssertEqual(channels.paid.map(\.part.feeSats), [128, 98, 68, 38], "A part may spend only what is left of the fee shown")
        XCTAssertEqual(outcome, .settled(movedSats: 99878, feeSats: 120))
    }

    func testAPartQuotedAboveTheFeeLeftStopsTheMoveToShowTheNewFee() async throws {
        let channels = FakeChannels(movableSats: 100_000)
        channels.routes = 30000
        do {
            _ = try await channels.run(MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 30000, feeSats: 70, firstFeeSats: 32))
            XCTFail("Expected the fee to rise")
        } catch let MoveToSparkError.feeRose(movedSats) {
            XCTAssertEqual(movedSats, 60000)
            XCTAssertEqual(channels.paid.count, 2, "A part was paid above the fee shown")
        }
    }

    func testAPartThatDoesNotSendIsHalved() async throws {
        let channels = FakeChannels(movableSats: 40000)
        var tried: [UInt64] = []
        let outcome = try await MoveToSparkManager.payParts(
            MoveToSparkQuote(invoice: "lnbcrt1first", amountSats: 39968, feeSats: 200, firstFeeSats: 32),
            movableSats: { channels.movableSats },
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { bolt11, part, _, _ in
                tried.append(part.amountSats)
                guard part.amountSats <= 10000 else { throw NodeError.RouteNotFound(message: "no route") }
                return try channels.pay(bolt11, part)
            }
        )
        XCTAssertEqual(Array(tried.prefix(3)), [39968, 19984, 9992])
        XCTAssertEqual(outcome, .settled(movedSats: 39878, feeSats: 120))
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
            newInvoice: { "lnbcrt1next" },
            quotePart: { channels.quotePart(limitSats: $1, wantedSats: $2) },
            pay: { _, _, _, _ in
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
        MoveToSparkPayments.removeAll()
        XCTAssertFalse(MoveToSparkPayments.contains("abcd"))
    }
}
