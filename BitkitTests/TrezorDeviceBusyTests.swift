@testable import Bitkit
import BitkitCore
import XCTest

/// Truth table for `Error.isTrezorDeviceBusy()` — the typed `TrezorError.DeviceBusy` a locked
/// device surfaces since bitkit-core 0.3.9.
final class TrezorDeviceBusyTests: XCTestCase {
    func testDeviceBusyReturnsTrue() {
        XCTAssertTrue(TrezorError.DeviceBusy.isTrezorDeviceBusy())
    }

    func testNonBusyErrorsReturnFalse() {
        XCTAssertFalse(TrezorError.Timeout.isTrezorDeviceBusy())
        XCTAssertFalse(TrezorError.DeviceDisconnected.isTrezorDeviceBusy())
        XCTAssertFalse(TrezorError.UserCancelled.isTrezorDeviceBusy())
        XCTAssertFalse(Bitkit.AppError(message: "sign failed", debugMessage: nil).isTrezorDeviceBusy())
        XCTAssertFalse(CancellationError().isTrezorDeviceBusy())
    }

    /// `ServiceQueue` boxes the raw `TrezorError` into an `AppError`, so the check must see through it.
    /// `AppError` is qualified as `Bitkit.AppError` because `Errors.swift` is also compiled into this
    /// test target, so an unqualified name would resolve to the duplicate and fail the cast.
    func testDeviceBusyWrappedInAppErrorReturnsTrue() {
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.DeviceBusy).isTrezorDeviceBusy())
    }

    func testNonBusyWrappedInAppErrorReturnsFalse() {
        XCTAssertFalse(Bitkit.AppError(error: TrezorError.Timeout).isTrezorDeviceBusy())
        XCTAssertFalse(Bitkit.AppError(error: TrezorError.UserCancelled).isTrezorDeviceBusy())
    }

    func testPresenterMapsDeviceBusyToUnlockPrompt() {
        XCTAssertEqual(
            TrezorErrorPresenter.userMessage(from: Bitkit.AppError(error: TrezorError.DeviceBusy)),
            t("hardware__device_busy")
        )
    }

    func testPresenterPassesUnrelatedMessageThrough() {
        XCTAssertEqual(TrezorErrorPresenter.mapMessage("some unmapped detail"), "some unmapped detail")
    }

    func testPresenterMapsPairingCodeFailureToInvalidPrompt() {
        XCTAssertEqual(TrezorErrorPresenter.mapMessage("Code verification failed"), t("hardware__pairing_code_invalid"))
    }

    /// A message-signature verification error shares the "verification failed" phrasing but is not a
    /// pairing failure, so it must fall through rather than showing the pairing-code prompt.
    func testPresenterDoesNotMapMessageVerificationToPairingPrompt() {
        let message = "Bitcoin message verification failed"
        XCTAssertNotEqual(TrezorErrorPresenter.mapMessage(message), t("hardware__pairing_code_invalid"))
        XCTAssertEqual(TrezorErrorPresenter.mapMessage(message), message)
    }
}
