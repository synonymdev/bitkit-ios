@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtSendFailureTests: XCTestCase {
    func testBackupFailureExplainsRecoveryWithoutClaimingRequestExpired() {
        let failure = UsdtSendView.submissionFailure(for: UsdtError.BackupUnavailable)
        XCTAssertEqual(failure.title, t("common__error"))
        XCTAssertEqual(failure.message, t("usdt__error_backup"))
        XCTAssertNotEqual(failure.title, t("wallet__payment_request_expired"))
        XCTAssertTrue(failure.canRetryRecovery)
    }

    func testRecoveryRemainsRetryableWhenTheLatestFailureIsRateLimitedOrOffline() {
        for error: UsdtError in [.RateLimited, .NetworkUnavailable] {
            let failure = UsdtSendView.submissionFailure(for: error, transferStatus: .pending, isRecoveryAttempt: true)
            XCTAssertTrue(failure.canRetryRecovery)
            XCTAssertEqual(failure.message, UsdtWalletManager.message(for: error))
            XCTAssertTrue(failure.isCurrent(for: .pending))
            XCTAssertFalse(failure.isCurrent(for: .confirmed))
            XCTAssertFalse(UsdtSendView.submissionFailure(for: error, transferStatus: .pending).canRetryRecovery)
        }
    }

    func testExpiredSubmissionKeepsItsSpecificExplanation() {
        let failure = UsdtSendView.submissionFailure(for: UsdtError.SubmissionDeadlineExpired)
        XCTAssertEqual(failure.title, t("wallet__payment_request_expired"))
        XCTAssertEqual(failure.message, t("wallet__payment_request_expired"))
    }

    func testPaymentRequestFailureKeepsItsLocalizedExplanation() {
        enum RequestFailure: LocalizedError {
            case unavailable
            var errorDescription: String? {
                "The request could not be updated."
            }
        }
        let failure = UsdtSendView.submissionFailure(for: RequestFailure.unavailable)
        XCTAssertEqual(failure.title, t("common__error"))
        XCTAssertEqual(failure.message, RequestFailure.unavailable.errorDescription)
    }

    func testBackupFailureDoesNotMaskLaterProgressOrTerminalStatus() {
        let failure = UsdtSendView.submissionFailure(for: UsdtError.BackupUnavailable, transferStatus: .pending)

        XCTAssertTrue(failure.isCurrent(for: .pending))
        XCTAssertFalse(failure.isCurrent(for: nil))
        let updatedStatuses: [UsdtTransferStatus] = [.bridging, .bridgeNeedsAttention, .bridgeFailed, .bridgeRefunded, .failed, .replaced, .confirmed]
        for status in updatedStatuses {
            XCTAssertFalse(failure.isCurrent(for: status))
        }
    }

    func testExpiredSubmissionExplainsItsRecordedFailureButNeverMasksConfirmation() {
        let failure = UsdtSendView.submissionFailure(for: UsdtError.SubmissionDeadlineExpired, transferStatus: .failed)

        XCTAssertTrue(failure.isCurrent(for: .failed))
        XCTAssertFalse(failure.isCurrent(for: .confirmed))
        let alreadyConfirmed = UsdtSendView.submissionFailure(for: UsdtError.BackupUnavailable, transferStatus: .confirmed)
        XCTAssertFalse(alreadyConfirmed.isCurrent(for: .confirmed))
    }
}
