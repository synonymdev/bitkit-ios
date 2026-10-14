@testable import Bitkit
import XCTest

@MainActor
final class ReceiveInvoiceRefreshTests: XCTestCase {
    private var stored: [(String, Any?)] = []

    override func setUp() {
        super.setUp()
        stored = ["bolt11", "bip21", "onchainAddress"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for (key, _) in stored {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for (key, value) in stored {
            UserDefaults.standard.set(value, forKey: key)
        }
        super.tearDown()
    }

    func testOlderRefreshCannotReplaceNewerInvoiceOrMixItsAmount() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        wallet.invoiceNote = "older"
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.invoiceAmountSats = 2000
        wallet.invoiceNote = "newer"
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        wallet.releaseOlderInvoice()
        try await older.value
        XCTAssertEqual(wallet.bolt11, "ln-newer")
        XCTAssertTrue(wallet.bip21.contains("lightning=ln-newer"))
        XCTAssertTrue(wallet.bip21.contains("amount=0.00002"))
        XCTAssertTrue(wallet.bip21.contains("message=newer"))
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testRefreshUsesCapturedInputsAndPreservesEditsMadeWhileWaiting() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        wallet.invoiceNote = "older"
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        XCTAssertTrue(wallet.isReceiveInvoiceUpdating)
        wallet.invoiceAmountSats = 2000
        wallet.invoiceNote = "newer"
        wallet.releaseOlderInvoice()
        try await refresh.value
        XCTAssertTrue(wallet.bip21.contains("amount=0.00001"))
        XCTAssertTrue(wallet.bip21.contains("message=older"))
        XCTAssertEqual(wallet.invoiceAmountSats, 2000)
        XCTAssertEqual(wallet.invoiceNote, "newer")
    }

    func testFailureEndsPendingAndRetryUsesCurrentEdits() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 2000
        wallet.failNextInvoice = true
        do {
            try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
            XCTFail("Expected invoice failure")
        } catch {}
        XCTAssertNotNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        wallet.invoiceNote = "retry & note"
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertNil(wallet.receiveInvoiceError)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertEqual(URLComponents(string: wallet.bip21)?.queryItems?.first(where: { $0.name == "message" })?.value, "retry & note")
    }

    func testCancelledNewestRequestDoesNotStrandPendingOrRepublishStaleInvoice() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        refresh.cancel()
        wallet.releaseOlderInvoice()
        do { try await refresh.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        XCTAssertTrue(wallet.bolt11.isEmpty)
        XCTAssertNotNil(wallet.receiveInvoiceError)
        wallet.invoiceAmountSats = 2000
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testCancelledOlderRequestDoesNotClearNewerResult() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.invoiceAmountSats = 2000
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        older.cancel()
        wallet.releaseOlderInvoice()
        do { try await older.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(wallet.bolt11, "ln-newer")
        XCTAssertNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testOlderAddressRefreshCannotOverwriteNewerAddressOrInvoice() async throws {
        let wallet = GatedReceiveWallet()
        wallet.gateFirstAddress = true
        wallet.invoiceAmountSats = 2000
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderAddressStarted], timeout: 5)
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        wallet.releaseOlderAddress()
        try await older.value
        XCTAssertEqual(wallet.onchainAddress, "bcrt1qreceive")
        XCTAssertTrue(wallet.bip21.hasPrefix("bitcoin:bcrt1qreceive"))
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testAutoRejectsOnchainOnlyAndMismatchedCachedInvoices() {
        let wallet = GatedReceiveWallet()
        wallet.bolt11 = "ln-newer"
        wallet.bip21 = "bitcoin:bcrt1qreceive"
        XCTAssertFalse(wallet.hasCoherentReceiveInvoice)
        wallet.bip21 = "bitcoin:bcrt1qreceive?lightning=ln-older"
        XCTAssertFalse(wallet.hasCoherentReceiveInvoice)
        wallet.bip21 = "bitcoin:bcrt1qreceive?lightning=ln-newer"
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testAddressFailureCanBeRetried() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 2000
        wallet.failNextAddress = true
        do { try await wallet.refreshBip21(syncPublicPaykit: false); XCTFail("Expected address failure") } catch {}
        XCTAssertNotNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertNil(wallet.receiveInvoiceError)
    }
}

@MainActor
private final class GatedReceiveWallet: WalletViewModel {
    let olderStarted = XCTestExpectation(description: "Older invoice suspended")
    private var olderInvoice: CheckedContinuation<String, Never>?
    var failNextInvoice = false
    var failNextAddress = false
    var gateFirstAddress = false
    var addressCallCount = 0
    let olderAddressStarted = XCTestExpectation(description: "Older address suspended")
    private var olderAddress: CheckedContinuation<String, Never>?

    override func paymentId() async -> String? { nil }
    override func persistPreActivityMetadata(tags: [String] = []) async {}
    override func persistPreActivityMetadata(paymentId: String, paymentHash: String?, address: String, tags: [String]) async {}
    override func canCreateReceiveLightningInvoice(amountSats: UInt64?) -> Bool { true }
    override func refreshReusableOnchainAddress() async throws -> String {
        if failNextAddress { failNextAddress = false; throw TestError.failed }
        addressCallCount += 1
        if gateFirstAddress, addressCallCount == 1 {
            return await withCheckedContinuation {
                olderAddress = $0
                olderAddressStarted.fulfill()
            }
        }
        return "bcrt1qreceive"
    }

    override func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        if failNextInvoice { failNextInvoice = false; throw TestError.failed }
        if amountSats == 1000 {
            return await withCheckedContinuation { continuation in
                olderInvoice = continuation
                olderStarted.fulfill()
            }
        }
        return "ln-newer"
    }

    func releaseOlderInvoice() {
        olderInvoice?.resume(returning: "ln-older")
        olderInvoice = nil
    }

    func releaseOlderAddress() {
        olderAddress?.resume(returning: "bcrt1qolder")
        olderAddress = nil
    }

    private enum TestError: Error { case failed }
}
