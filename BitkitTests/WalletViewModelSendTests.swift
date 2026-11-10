@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class WalletViewModelSendTests: XCTestCase {
    private struct FeeFetchError: Error {}

    func testRetiredRoutingFeeEstimatesCannotMakeANewSendPayable() async {
        for retirement in ["replacement", "reset", "cancellation"] {
            let started = expectation(description: "Routing estimate started")
            var continuation: CheckedContinuation<UInt64, Never>?
            let wallet = RoutingFeeWallet()
            wallet.routingFeeEstimateSats = 20
            wallet.estimate = { invoice in
                guard invoice == "old-invoice" else { return 0 }
                return await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            let task = Task { await wallet.refreshRoutingFeeEstimate(bolt11: "old-invoice", amountSats: nil) }
            await fulfillment(of: [started], timeout: 3)
            XCTAssertNil(wallet.routingFeeEstimateSats, "A pending estimate cannot reuse a previous route's fee")

            switch retirement {
            case "replacement":
                await wallet.refreshRoutingFeeEstimate(bolt11: "new-invoice", amountSats: nil)
            case "reset":
                wallet.resetSendState(speed: .normal)
            default:
                task.cancel()
            }
            continuation?.resume(returning: 50)
            await task.value
            XCTAssertEqual(wallet.routingFeeEstimateSats, retirement == "replacement" ? 0 : nil)
        }

        let wallet = RoutingFeeWallet()
        wallet.routingFeeEstimateSats = 20
        let cancelled = Task { await wallet.refreshRoutingFeeEstimate(bolt11: "retired-invoice", amountSats: nil) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(wallet.routingFeeEstimateSats, 20, "An already-cancelled caller cannot invalidate the active estimate")
    }

    func testFeeRateDoesNotApplyToAnExpiredSendContext() async throws {
        snapshotAppDefaultsDomain()
        FeeEstimatesManager().devOverrideFeeEstimates = true
        let wallet = WalletViewModel()

        do {
            try await wallet.setFeeRate(speed: .normal, isCurrentSend: { false })
            XCTFail("Expected the expired send preparation to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertNil(wallet.selectedFeeRateSatsPerVByte)
        XCTAssertFalse(wallet.feeRateLoadFailed)
    }

    func testUtxoSelectionDoesNotOverwriteAnExpiredSendAfterAwait() async throws {
        for isMax in [false, true] {
            let wallet = WalletViewModel()
            wallet.sendAmountSats = isMax ? 99819 : 10000
            wallet.selectedFeeRateSatsPerVByte = 1
            wallet.isMaxAmountSend = isMax
            let original = SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "a", count: 64), vout: 0), valueSats: 60000)
            let replacement = SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "b", count: 64), vout: 0), valueSats: 40000)
            wallet.selectedUtxos = [original]
            var isCurrent = true
            var crossedSelection = false
            let finishSelection = {
                await Task.yield()
                crossedSelection = true
                isCurrent = false
                return [replacement]
            }
            do {
                try await wallet.setUtxoSelection(
                    coinSelectionAlgorythm: .branchAndBound, isCurrentSend: { isCurrent },
                    listSpendable: {
                        XCTAssertTrue(isMax)
                        return await finishSelection()
                    },
                    selectForAmount: { _, _, _ in
                        XCTAssertFalse(isMax)
                        return await finishSelection()
                    }
                )
                XCTFail("An expired send must not apply the selection after its await")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(crossedSelection)
            XCTAssertEqual(wallet.selectedUtxos, [original])
        }
    }

    func testRestoringTheScannedAmountClearsCoinsChosenForAnEditedAmount() {
        let wallet = WalletViewModel()
        let utxo = SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "a", count: 64), vout: 0), valueSats: 20000)

        wallet.sendAmountSats = 10000
        wallet.selectedUtxos = [utxo]
        wallet.isMaxAmountSend = true
        wallet.restoreScannedSendAmount(50000)
        XCTAssertEqual(wallet.sendAmountSats, 50000)
        XCTAssertNil(wallet.selectedUtxos)
        XCTAssertFalse(wallet.isMaxAmountSend)

        wallet.selectedUtxos = [utxo]
        wallet.restoreScannedSendAmount(50000)
        XCTAssertEqual(wallet.selectedUtxos?.map(\.valueSats), [20000])
    }

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

@MainActor
private final class RoutingFeeWallet: WalletViewModel {
    var estimate: (String) async throws -> UInt64 = { _ in 0 }

    override func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64 {
        try await estimate(bolt11)
    }
}
