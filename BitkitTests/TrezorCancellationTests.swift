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
}
