@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class WalletViewModelSendTests: XCTestCase {
    private struct FeeFetchError: Error {}

    func testSoftwareMaxUsesSpendableOutputsInsteadOfFixedAmountSelection() async throws {
        let wallet = WalletViewModel()
        wallet.sendAmountSats = 99819
        wallet.selectedFeeRateSatsPerVByte = 1
        wallet.isMaxAmountSend = true
        let coins = [60000, 40000].enumerated().map { index, value in
            SpendableUtxo(outpoint: OutPoint(txid: String(repeating: index == 0 ? "a" : "b", count: 64), vout: 0), valueSats: UInt64(value))
        }
        var fixedSelections = 0
        var listCalls = 0
        do {
            try await wallet.setUtxoSelection(
                coinSelectionAlgorythm: .branchAndBound,
                listSpendable: { listCalls += 1; return coins },
                selectForAmount: { amount, rate, _ in
                    fixedSelections += 1
                    XCTAssertEqual(amount, 99819)
                    XCTAssertEqual(rate, 1)
                    throw FeeFetchError()
                }
            )
        } catch {
            XCTFail("Max must use the drain inputs without fixed-payment selection: \(error)")
        }
        XCTAssertEqual(wallet.selectedUtxos, coins)
        XCTAssertEqual(fixedSelections, 0)
        XCTAssertEqual(listCalls, 1)
        wallet.isMaxAmountSend = false
        wallet.sendAmountSats = 10000
        try await wallet.setUtxoSelection(
            coinSelectionAlgorythm: .branchAndBound,
            listSpendable: { XCTFail("Fixed payment must retain its selected algorithm"); return coins },
            selectForAmount: { amount, rate, _ in
                fixedSelections += 1
                XCTAssertEqual(amount, 10000)
                XCTAssertEqual(rate, 1)
                return [coins[0]]
            }
        )
        XCTAssertEqual(wallet.selectedUtxos, [coins[0]])
        XCTAssertEqual(fixedSelections, 1)
    }

    func testFeeRateLoadRetriesAFailedFetchAndRecovers() async throws {
        let wallet = WalletViewModel()
        var attempts = 0

        try await wallet.loadFeeRateWithRetry(speed: .normal, retryDelay: .milliseconds(1)) { _ in
            attempts += 1
            if attempts == 1 {
                throw FeeFetchError()
            }
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(wallet.feeRateLoadFailed)
    }

    func testFeeRateLoadGivesUpAndFlagsTheFailureSoTheSwipeCanOfferARetry() async {
        let wallet = WalletViewModel()
        var attempts = 0

        do {
            try await wallet.loadFeeRateWithRetry(speed: .normal, retryDelay: .milliseconds(1)) { _ in
                attempts += 1
                throw FeeFetchError()
            }
            XCTFail("Expected the fee rate load to fail")
        } catch {
            XCTAssertTrue(error is FeeFetchError)
        }

        XCTAssertEqual(attempts, WalletViewModel.feeRateLoadAttempts)
        XCTAssertTrue(wallet.feeRateLoadFailed)
        XCTAssertNil(wallet.selectedFeeRateSatsPerVByte)

        wallet.resetSendState(speed: .normal)
        XCTAssertFalse(wallet.feeRateLoadFailed)
    }

    func testFeeRateLoadRetryClearsAPreviousFailureBeforeFetching() async throws {
        let wallet = WalletViewModel()
        _ = try? await wallet.loadFeeRateWithRetry(speed: .normal, retryDelay: .milliseconds(1)) { _ in throw FeeFetchError() }
        XCTAssertTrue(wallet.feeRateLoadFailed)

        var flagWhileFetching: Bool?
        try await wallet.loadFeeRateWithRetry(speed: .normal, retryDelay: .milliseconds(1)) { _ in
            flagWhileFetching = wallet.feeRateLoadFailed
        }

        XCTAssertEqual(flagWhileFetching, false)
        XCTAssertFalse(wallet.feeRateLoadFailed)
    }

    func testFeeRateLoadDoesNotFlagCancellationAsAFailure() async {
        let wallet = WalletViewModel()
        var attempts = 0

        do {
            try await wallet.loadFeeRateWithRetry(speed: .normal, retryDelay: .milliseconds(1)) { _ in
                attempts += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(wallet.feeRateLoadFailed)
    }

    func testWaitForLightningPaymentTimeoutUnwindsWithoutEvent() async {
        let wallet = WalletViewModel()
        let unwound = expectation(description: "wait unwound after timeout")
        var timedOutHash: String?

        Task { @MainActor in
            do {
                _ = try await wallet.waitForLightningPayment(hash: "unwatched-hash", timeoutSeconds: 0.05) { hash in
                    timedOutHash = hash
                }
                XCTFail("Expected PaymentTimeoutError")
            } catch is Bitkit.PaymentTimeoutError {
                unwound.fulfill()
            } catch {
                XCTFail("Expected PaymentTimeoutError, got \(type(of: error)): \(error)")
            }
        }

        await fulfillment(of: [unwound], timeout: 2)
        XCTAssertEqual(timedOutHash, "unwatched-hash")
    }

    func testWaitForLightningPaymentUnwindsOnCancel() async {
        let wallet = WalletViewModel()
        let unwound = expectation(description: "wait unwound after cancel")

        let waitTask = Task { @MainActor in
            do {
                _ = try await wallet.waitForLightningPayment(hash: "unwatched-hash", timeoutSeconds: 60)
                XCTFail("Expected cancellation")
            } catch {
                unwound.fulfill()
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        waitTask.cancel()
        await fulfillment(of: [unwound], timeout: 2)
    }
}
