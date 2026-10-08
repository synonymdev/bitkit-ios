@testable import Bitkit
import LDKNode
import XCTest

final class SendConfirmationSwipeTests: XCTestCase {
    func testManualSelectionFailureStopsSubmissionAndAllowsRetry() async throws {
        enum SelectionError: Error { case unavailable }
        var attempts = 0
        var openedSelection = false
        for shouldFail in [true, false] {
            do {
                try await SendConfirmationView.requireManualCoinSelection(
                    walletType: .onchain,
                    isHardwarePayment: false,
                    coinSelectionMethod: .manual,
                    selectedUtxos: nil
                ) {
                    attempts += 1
                    if shouldFail { throw SelectionError.unavailable }
                    openedSelection = true
                }
                XCTFail("Manual selection must stop before payment authorization")
            } catch SelectionError.unavailable {
                XCTAssertTrue(shouldFail)
            } catch is CancellationError {
                XCTAssertFalse(shouldFail)
            }
            XCTAssertEqual(openedSelection, !shouldFail)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testManualSelectionInterruptsSubmissionUntilCoinsAreChosen() async throws {
        for selectedUtxos: [SpendableUtxo]? in [nil, []] {
            var openedSelection = false
            do {
                try await SendConfirmationView.requireManualCoinSelection(
                    walletType: .onchain,
                    isHardwarePayment: false,
                    coinSelectionMethod: .manual,
                    selectedUtxos: selectedUtxos
                ) {
                    openedSelection = true
                }
                XCTFail("Missing manual coins must stop before payment authorization")
            } catch is CancellationError {} catch {
                XCTFail("Expected cancellation to reset the swipe, got \(error)")
            }
            XCTAssertTrue(openedSelection)
        }
    }

    func testCoinSelectionGuardPreservesPreparedAndAutomaticPayments() async throws {
        let coins = [SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "1", count: 64), vout: 0), valueSats: 10000)]
        let cases: [(WalletType, Bool, CoinSelectionMethod, [SpendableUtxo]?)] = [
            (.onchain, false, .manual, coins),
            (.onchain, false, .autopilot, nil),
            (.lightning, false, .manual, nil),
            (.onchain, true, .manual, nil),
        ]
        for (walletType, isHardwarePayment, method, selectedUtxos) in cases {
            try await SendConfirmationView.requireManualCoinSelection(
                walletType: walletType,
                isHardwarePayment: isHardwarePayment,
                coinSelectionMethod: method,
                selectedUtxos: selectedUtxos
            ) {
                XCTFail("Prepared coins, automatic mode, Lightning and hardware must keep their existing payment path")
            }
        }
    }

    func testWalletPreparationKeepsSwipeDisabledWithKnownFees() {
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5,
            isPreparingWallet: true
        ))
    }

    func testPreparingRequestKeepsSwipeDisabledAndLoadingWithKnownFees() {
        for walletType in [WalletType.lightning, .onchain] {
            XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
                walletType: walletType,
                isHardwarePayment: false,
                isHardwareConfirmationUnavailable: false,
                feeRate: 5,
                isPreparingRequest: true
            ))
        }
        XCTAssertTrue(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: false,
            feeRateLoadFailed: false,
            isPreparingRequest: true
        ))
    }

    func testOnchainPaymentWithoutFeeRateDisablesSwipe() {
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
    }

    func testOnchainPaymentWithFeeRateEnablesSwipe() {
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5
        ))
    }

    func testLightningPaymentNeverWaitsForFeeRate() {
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .lightning,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
    }

    func testHardwarePaymentKeepsItsOwnRule() {
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: true,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: true,
            isHardwareConfirmationUnavailable: true,
            feeRate: 5
        ))
    }

    func testSwipeShowsItsSpinnerWhileTheFeeRateLoads() {
        XCTAssertTrue(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: true,
            feeRateLoadFailed: false
        ))
    }

    func testSwipeStopsItsSpinnerOnceTheFeeRateLoadFailed() {
        XCTAssertFalse(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: true,
            feeRateLoadFailed: true
        ))
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
    }

    func testAutomaticPaymentKeepsTheSpinnerWhateverTheFeeRateState() {
        for feeRateLoadFailed in [false, true] {
            XCTAssertTrue(SendConfirmationView.isSwipeLoading(
                hasStartedAutomaticPayment: true,
                isFeeRateMissing: true,
                feeRateLoadFailed: feeRateLoadFailed
            ))
        }
    }

    func testFeeRateIsOnlyMissingForSoftwareOnchainPayments() {
        for walletType in [WalletType.lightning, .onchain] {
            for isHardwarePayment in [false, true] {
                for feeRate in [nil, UInt32(5)] {
                    XCTAssertEqual(
                        SendConfirmationView.isFeeRateMissing(walletType: walletType, isHardwarePayment: isHardwarePayment, feeRate: feeRate),
                        walletType == .onchain && !isHardwarePayment && feeRate == nil
                    )
                }
            }
        }
    }
}
