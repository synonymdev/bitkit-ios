@testable import Bitkit
import BitkitCore
import XCTest

/// Truth table for `Error.isTrezorUserCancellation()`, mirroring bitkit-android's
/// `TrezorExceptionExtTest`: the three on-device cancellation cases are treated as user cancellations,
/// everything else (including a Trezor timeout) is not.
final class TrezorCancellationTests: XCTestCase {
    func testUserCancellationCasesReturnTrue() {
        XCTAssertTrue(TrezorError.UserCancelled.isTrezorUserCancellation())
        XCTAssertTrue(TrezorError.PinCancelled.isTrezorUserCancellation())
        XCTAssertTrue(TrezorError.PassphraseCancelled.isTrezorUserCancellation())
    }

    func testNonCancellationErrorsReturnFalse() {
        XCTAssertFalse(TrezorError.Timeout.isTrezorUserCancellation())
        XCTAssertFalse(TrezorError.DeviceDisconnected.isTrezorUserCancellation())
        XCTAssertFalse(AppError(message: "sign failed", debugMessage: nil).isTrezorUserCancellation())
        XCTAssertFalse(CancellationError().isTrezorUserCancellation())
    }

    /// On device, `ServiceQueue` boxes the raw `TrezorError` into an `AppError` before it reaches the
    /// view model — the exact case that leaked a spurious error toast. The cancellation check must see
    /// through the wrapper.
    ///
    /// `AppError` is qualified as `Bitkit.AppError`: `Errors.swift` is also compiled into this test
    /// target, so an unqualified `AppError` would resolve to the test-target copy and fail the
    /// `self as? Bitkit.AppError` cast inside `isTrezorUserCancellation()`.
    func testCancellationWrappedInAppErrorReturnsTrue() {
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.UserCancelled).isTrezorUserCancellation())
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.PinCancelled).isTrezorUserCancellation())
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.PassphraseCancelled).isTrezorUserCancellation())
    }

    func testNonCancellationWrappedInAppErrorReturnsFalse() {
        XCTAssertFalse(Bitkit.AppError(error: TrezorError.Timeout).isTrezorUserCancellation())
        XCTAssertFalse(Bitkit.AppError(error: TrezorError.DeviceDisconnected).isTrezorUserCancellation())
    }
}
