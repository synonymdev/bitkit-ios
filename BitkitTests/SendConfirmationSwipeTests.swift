@testable import Bitkit
import XCTest

final class SendConfirmationSwipeTests: XCTestCase {
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
