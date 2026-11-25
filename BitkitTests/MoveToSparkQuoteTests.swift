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
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels, targetSats: nil)
        XCTAssertEqual(quote, MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 99968, feeSats: 32))
        XCTAssertEqual(services.quotedAmounts, [99498, 99968])
    }

    func testQuoteKeepsASmallerTarget() async throws {
        let services = FakeServices()
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels, targetSats: 50000)
        XCTAssertEqual(quote.amountSats, 50000)
        XCTAssertEqual(quote.feeSats, 32)
        XCTAssertEqual(services.quotedAmounts, [50000])
    }

    func testQuoteFallsBackToTheLastFittingAmount() async throws {
        let services = FakeServices()
        services.estimate = { amount in
            guard amount == 99498 else { throw NodeError.RouteNotFound(message: "no route") }
            return 30
        }
        let quote = try await MoveToSparkManager(services: services).makeQuote(channels: channels, targetSats: nil)
        XCTAssertEqual(quote.amountSats, 99498)
        XCTAssertEqual(quote.feeSats, 32)
    }

    func testNoRouteOnTheFirstRoundIsTooLarge() async {
        let services = FakeServices()
        services.estimate = { _ in throw NodeError.RouteNotFound(message: "no route") }
        await assertQuoteThrows(services, expected: .tooLarge(amountSats: 99498))
    }

    func testAFeeThatNeverFitsIsTooLarge() async {
        let services = FakeServices()
        var estimate: UInt64 = 500
        services.estimate = { _ in
            estimate += 100
            return estimate
        }
        await assertQuoteThrows(services, expected: .tooLarge(amountSats: 99098))
        XCTAssertEqual(services.quotedAmounts, [99498, 99398, 99298, 99198])
    }

    func testOtherEstimateErrorsAreRethrown() async {
        let services = FakeServices()
        services.estimate = { _ in throw OtherError() }
        do {
            _ = try await MoveToSparkManager(services: services).makeQuote(channels: channels, targetSats: nil)
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
            _ = try await MoveToSparkManager(services: services).makeQuote(channels: channels ?? self.channels, targetSats: nil)
            XCTFail("Expected \(expected)", line: line)
        } catch let error as MoveToSparkError {
            switch (error, expected) {
            case let (.tooLarge(a), .tooLarge(b)): XCTAssertEqual(a, b, line: line)
            case (.nothingToMove, .nothingToMove), (.sparkUnavailable, .sparkUnavailable): break
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
