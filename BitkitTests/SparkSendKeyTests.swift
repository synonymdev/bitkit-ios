@testable import Bitkit
import BreezSdkSpark
import XCTest

final class SparkSendKeyTests: XCTestCase {
    /// The BIP39 seed of `abandon … about` with passphrase `TREZOR`, from the BIP39 test vectors.
    private let seed = (
        "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2c"
            + "f141630c7a3c4ab7c81b2f001698e7463b04"
    ).hexaData
    /// Bytes 0 to 31.
    private let paymentHash = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    /// The host app's saved attempts, put back after each test.
    private var savedAttempts: Data?

    override func setUp() {
        super.setUp()
        savedAttempts = UserDefaults.standard.data(forKey: "sparkSendAttempts")
        SparkSendAttempts.clear()
    }

    override func tearDown() {
        UserDefaults.standard.set(savedAttempts, forKey: "sparkSendAttempts")
        super.tearDown()
    }

    /// The same vector is asserted by Android's `SparkSendKeyTest`, so a wallet restored on the other app derives the
    /// same keys.
    func testDerivesTheSharedTestVector() {
        let secret = SparkSendKey.secret(seed: seed)

        XCTAssertEqual(secret.hex, "577ceb10411255cef07e3f49bd7e5239de07586c7457f65ee72ee53737361a98")
        XCTAssertEqual(SparkSendKey.key(secret: secret, paymentHash: paymentHash, attempt: 0), "8d92d8bf-76f3-56fe-8958-8e440acb64fc")
        XCTAssertEqual(SparkSendKey.key(secret: secret, paymentHash: paymentHash, attempt: 1), "712dea1f-8268-5e52-a280-aac86bc60b59")
    }

    func testReadsThePaymentHashInEitherCase() {
        let secret = SparkSendKey.secret(seed: seed)

        XCTAssertEqual(
            SparkSendKey.key(secret: secret, paymentHash: paymentHash.uppercased(), attempt: 0),
            SparkSendKey.key(secret: secret, paymentHash: paymentHash, attempt: 0)
        )
    }

    func testAFirstAttemptTakesTheFirstKey() {
        let secret = SparkSendKey.secret(seed: seed)

        XCTAssertEqual(SparkSendAttempts.next(paymentHash: paymentHash, secret: secret, failedIds: []), 0)
    }

    func testARetryReusesItsAttemptsKeyUntilSparkListsThatAttemptFailed() {
        let secret = SparkSendKey.secret(seed: seed)
        SparkSendAttempts.set(paymentHash: paymentHash, attempt: 1, expiresAt: 2000, now: 1000)
        let firstFailed: Set = [SparkSendKey.key(secret: secret, paymentHash: paymentHash, attempt: 0)]

        XCTAssertEqual(SparkSendAttempts.next(paymentHash: paymentHash, secret: secret, failedIds: firstFailed), 1)
    }

    func testARetryTakesTheNextKeyOnceSparkListsItsAttemptFailed() {
        let secret = SparkSendKey.secret(seed: seed)
        SparkSendAttempts.set(paymentHash: paymentHash, attempt: 0, expiresAt: 2000, now: 1000)
        let failed = Set([0, 1].map { SparkSendKey.key(secret: secret, paymentHash: paymentHash, attempt: $0) })

        XCTAssertEqual(SparkSendAttempts.next(paymentHash: paymentHash, secret: secret, failedIds: failed), 2)
    }

    func testAnExpiredInvoicesAttemptIsDropped() {
        let secret = SparkSendKey.secret(seed: seed)
        SparkSendAttempts.set(paymentHash: paymentHash, attempt: 3, expiresAt: 1500, now: 1000)
        SparkSendAttempts.set(paymentHash: String(repeating: "ab", count: 32), attempt: 0, expiresAt: 3000, now: 2000)

        XCTAssertEqual(SparkSendAttempts.next(paymentHash: paymentHash, secret: secret, failedIds: []), 0)
    }

    func testAShortBalanceUnderAReusedKeyStaysInDoubt() {
        let shortBalance = SdkError.InsufficientFunds(tokenIdentifier: nil)

        // An earlier attempt under the key may have committed a transfer, which Spark returns once it can pick leaves.
        let reused = Bitkit.SparkManager.bolt11SendFailure(shortBalance, isReusedKey: true)
        let fresh = Bitkit.SparkManager.bolt11SendFailure(shortBalance, isReusedKey: false)

        XCTAssertFalse(reused is Bitkit.ChannelFreeRailSendRefused, "\(reused)")
        XCTAssertTrue(fresh is Bitkit.ChannelFreeRailSendRefused, "\(fresh)")
    }

    func testLeavesSparkCantSelectKeepTheSendInDoubtUnderAnyKey() {
        // The SDK selects leaves again after an operator error, so the failure can follow a committed transfer.
        let reused = Bitkit.SparkManager.bolt11SendFailure(leafSelectionFailure, isReusedKey: true)
        let fresh = Bitkit.SparkManager.bolt11SendFailure(leafSelectionFailure, isReusedKey: false)

        XCTAssertFalse(reused is Bitkit.ChannelFreeRailSendRefused, "\(reused)")
        XCTAssertFalse(fresh is Bitkit.ChannelFreeRailSendRefused, "\(fresh)")
    }

    func testAnExpiryUnderAReusedKeyKeepsTheSendInDoubt() {
        // The attempt that used the key may have committed a transfer before the invoice expired.
        let expired = SdkError.InvalidInput("invoice has expired")

        let reused = Bitkit.SparkManager.bolt11SendFailure(expired, isReusedKey: true)
        let fresh = Bitkit.SparkManager.bolt11SendFailure(expired, isReusedKey: false)

        XCTAssertFalse(reused is Bitkit.ChannelFreeRailSendRefused, "\(reused)")
        XCTAssertTrue(fresh is Bitkit.ChannelFreeRailSendRefused, "\(fresh)")
    }

    func testANewKeyWaitsWhileTheEarlierAttemptIsInDoubt() {
        XCTAssertTrue(Bitkit.SparkManager.waitsForHold(isReusedKey: false, previousAttempt: 0, isInDoubt: true))
        XCTAssertFalse(Bitkit.SparkManager.waitsForHold(isReusedKey: true, previousAttempt: 0, isInDoubt: true))
        XCTAssertFalse(Bitkit.SparkManager.waitsForHold(isReusedKey: false, previousAttempt: 0, isInDoubt: false))
        XCTAssertFalse(Bitkit.SparkManager.waitsForHold(isReusedKey: false, previousAttempt: nil, isInDoubt: true))
    }

    func testAFailedPaymentSparkReturnsIsRefused() {
        XCTAssertThrowsError(try Bitkit.SparkManager.checkSentPayment(.failed)) {
            XCTAssertTrue($0 is Bitkit.ChannelFreeRailSendRefused, "\($0)")
        }
        XCTAssertNoThrow(try Bitkit.SparkManager.checkSentPayment(.pending))
        XCTAssertNoThrow(try Bitkit.SparkManager.checkSentPayment(.completed))
    }

    func testAnInvoiceExpiringDuringALeafRetryEndsWithTheLeafFailure() async {
        var sends = 0

        do {
            _ = try await Bitkit.SparkManager.sendRetryingLeafSelection(retryDelay: .zero, canRetry: { true }) {
                sends += 1
                if sends == 1 {
                    throw leafSelectionFailure
                }
                throw SdkError.InvalidInput("invoice has expired")
            }
            XCTFail("Expected the send to fail")
        } catch {
            XCTAssertTrue(Bitkit.SparkManager.isLeafSelectionFailure(error), "\(error)")
        }
    }

    func testAShortBalanceOnALeafRetryEndsWithTheLeafFailure() async {
        var sends = 0

        do {
            _ = try await Bitkit.SparkManager.sendRetryingLeafSelection(retryDelay: .zero, canRetry: { true }) {
                sends += 1
                if sends == 1 {
                    throw leafSelectionFailure
                }
                throw SdkError.InsufficientFunds(tokenIdentifier: nil)
            }
            XCTFail("Expected the send to fail")
        } catch {
            XCTAssertTrue(Bitkit.SparkManager.isLeafSelectionFailure(error), "\(error)")
        }
    }

    func testASendRetriesWhileSparkCantSelectItsLeaves() async throws {
        var sends = 0

        let sent = try await Bitkit.SparkManager.sendRetryingLeafSelection(retryDelay: .zero, canRetry: { true }) {
            sends += 1
            if sends == 1 {
                throw leafSelectionFailure
            }
            return "sent"
        }

        XCTAssertEqual(sent, "sent")
        XCTAssertEqual(sends, 2)
    }

    func testASendStopsRetryingOnceItCanNoLongerGo() async {
        var sends = 0

        do {
            _ = try await Bitkit.SparkManager.sendRetryingLeafSelection(retryDelay: .zero, canRetry: { false }) {
                sends += 1
                throw leafSelectionFailure
            }
            XCTFail("the send went out")
        } catch {
            XCTAssertTrue(Bitkit.SparkManager.isLeafSelectionFailure(error), "\(error)")
        }
        XCTAssertEqual(sends, 1)
    }

    func testASendStopsRetryingAfterItsLastRetry() async {
        var sends = 0

        do {
            _ = try await Bitkit.SparkManager.sendRetryingLeafSelection(retryDelay: .zero, canRetry: { true }) {
                sends += 1
                throw leafSelectionFailure
            }
            XCTFail("the send went out")
        } catch {
            XCTAssertTrue(Bitkit.SparkManager.isLeafSelectionFailure(error), "\(error)")
        }
        XCTAssertEqual(sends, 1 + Bitkit.SparkManager.leafSelectionRetries)
    }

    func testASendIsNotRetriedForOtherFailures() async {
        var sends = 0

        do {
            _ = try await Bitkit.SparkManager.sendRetryingLeafSelection(retryDelay: .zero, canRetry: { true }) {
                sends += 1
                throw SdkError.InsufficientFunds(tokenIdentifier: nil)
            }
            XCTFail("the send went out")
        } catch {}
        XCTAssertEqual(sends, 1)
    }

    func testARefusedAttemptGivesBackTheEarlierOne() {
        SparkSendAttempts.set(paymentHash: paymentHash, attempt: 1, expiresAt: 2000, now: 1000)
        SparkSendAttempts.set(paymentHash: paymentHash, attempt: 2, expiresAt: 2000, now: 1000)

        SparkSendAttempts.restore(paymentHash: paymentHash, attempt: 1, expiresAt: 2000)
        XCTAssertEqual(SparkSendAttempts.latest(paymentHash: paymentHash), 1)

        SparkSendAttempts.restore(paymentHash: paymentHash, attempt: nil, expiresAt: 2000)
        XCTAssertNil(SparkSendAttempts.latest(paymentHash: paymentHash))
    }

    private let leafSelectionFailure = SdkError.SparkError("Tree service error: generic error: Failed to select leaves after all retries")
}
