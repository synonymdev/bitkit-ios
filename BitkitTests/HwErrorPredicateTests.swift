@testable import Bitkit
import BitkitCore
import XCTest

/// Truth tables for the `isJade*` predicates and the vendor-neutral `isHw*` ones built on them.
/// `ServiceQueue` boxes core errors into an `AppError`, so every Jade case is checked raw and wrapped.
/// `AppError` is qualified as `Bitkit.AppError` because `Errors.swift` is also compiled into this test
/// target, so an unqualified name would resolve to the duplicate and fail the cast.
final class HwErrorPredicateTests: XCTestCase {
    private let sessionFailures: [JadeError] = [
        .TransportError(errorDetails: "link lost"),
        .DeviceDisconnected,
        .ConnectionError(errorDetails: "refused"),
        .Timeout,
        .NotConnected,
        .NotInitialized,
        .IoError(errorDetails: "broken pipe"),
    ]

    private let otherErrors: [JadeError] = [
        .DeviceNotFound,
        .ProtocolError(errorDetails: "bad frame"),
        .DeviceUninitialized,
        .InvalidPin,
        .NetworkMismatch(errorDetails: "testnet"),
        .InvalidPath(errorDetails: "m/0"),
        .InvalidPsbt(errorDetails: "bad psbt"),
        .PsbtTooLarge(size: 20000, max: 16384),
        .FingerprintMismatch(device: "aaaa", psbt: "bbbb"),
        .NothingSigned,
        .AddressMismatch(expected: "bc1qexpected", returned: "bc1qreturned"),
        .PinServerError(errorDetails: "unreachable"),
        .DeviceError(errorDetails: "device said no"),
    ]

    private func rawAndWrapped(_ error: JadeError) -> [Error] {
        [error, Bitkit.AppError(error: error)]
    }

    // MARK: - Unwrapping

    func testUnderlyingJadeErrorSeesThroughAppError() {
        XCTAssertEqual(JadeError.InvalidPin.underlyingJadeError, .InvalidPin)
        XCTAssertEqual(Bitkit.AppError(error: JadeError.InvalidPin).underlyingJadeError, .InvalidPin)
        XCTAssertNil(TrezorError.DeviceBusy.underlyingJadeError)
        XCTAssertNil(Bitkit.AppError(message: "boom", debugMessage: nil).underlyingJadeError)
        XCTAssertNil(CancellationError().underlyingJadeError)
    }

    // MARK: - Jade

    func testJadeUserCancellation() {
        for error in rawAndWrapped(.UserCancelled) {
            XCTAssertTrue(error.isJadeUserCancellation(), "\(error)")
        }
        for error in (sessionFailures + otherErrors + [.DeviceBusy, .DeviceLocked]).flatMap(rawAndWrapped) {
            XCTAssertFalse(error.isJadeUserCancellation(), "\(error)")
        }
        XCTAssertFalse(TrezorError.UserCancelled.isJadeUserCancellation())
        XCTAssertFalse(CancellationError().isJadeUserCancellation())
    }

    func testABusyOrLockedJadeIsBusy() {
        for error in rawAndWrapped(.DeviceBusy) + rawAndWrapped(.DeviceLocked) {
            XCTAssertTrue(error.isJadeDeviceBusy(), "\(error)")
        }
        for error in (sessionFailures + otherErrors + [.UserCancelled]).flatMap(rawAndWrapped) {
            XCTAssertFalse(error.isJadeDeviceBusy(), "\(error)")
        }
        XCTAssertFalse(TrezorError.DeviceBusy.isJadeDeviceBusy())
    }

    func testOutdatedJadeFirmwareIsAFirmwareError() {
        for error in rawAndWrapped(.UnsupportedFirmware(installed: "0.1.0", required: "1.0.34")) {
            XCTAssertTrue(error.isJadeFirmwareError(), "\(error)")
        }
        for error in (sessionFailures + otherErrors + [.UserCancelled, .DeviceBusy]).flatMap(rawAndWrapped) {
            XCTAssertFalse(error.isJadeFirmwareError(), "\(error)")
        }
    }

    func testTransportLevelJadeFailuresAreSessionFailures() {
        for error in sessionFailures.flatMap(rawAndWrapped) {
            XCTAssertTrue(error.isJadeSessionFailure(), "\(error)")
        }
        let notSessionFailures: [JadeError] = otherErrors + [
            .UserCancelled,
            .DeviceBusy,
            .DeviceLocked,
            .UnsupportedFirmware(installed: "0.1.0", required: "1.0.34"),
        ]
        for error in notSessionFailures.flatMap(rawAndWrapped) {
            XCTAssertFalse(error.isJadeSessionFailure(), "\(error)")
        }
        XCTAssertFalse(TrezorError.DeviceDisconnected.isJadeSessionFailure())
    }

    // MARK: - Either vendor

    func testHwUserCancellationCoversBothVendors() {
        XCTAssertTrue(JadeError.UserCancelled.isHwUserCancellation())
        XCTAssertTrue(Bitkit.AppError(error: JadeError.UserCancelled).isHwUserCancellation())
        XCTAssertTrue(TrezorError.UserCancelled.isHwUserCancellation())
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.PinCancelled).isHwUserCancellation())
        XCTAssertFalse(JadeError.DeviceBusy.isHwUserCancellation())
        XCTAssertFalse(TrezorError.Timeout.isHwUserCancellation())
        XCTAssertFalse(CancellationError().isHwUserCancellation())
    }

    func testHwDeviceBusyCoversBothVendors() {
        XCTAssertTrue(JadeError.DeviceLocked.isHwDeviceBusy())
        XCTAssertTrue(Bitkit.AppError(error: JadeError.DeviceBusy).isHwDeviceBusy())
        XCTAssertTrue(TrezorError.DeviceBusy.isHwDeviceBusy())
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.DeviceBusy).isHwDeviceBusy())
        XCTAssertFalse(JadeError.Timeout.isHwDeviceBusy())
        XCTAssertFalse(TrezorError.Timeout.isHwDeviceBusy())
    }

    func testHwFirmwareErrorCoversBothVendors() {
        XCTAssertTrue(Bitkit.AppError(error: JadeError.UnsupportedFirmware(installed: "0.1.0", required: "1.0.34")).isHwFirmwareError())
        XCTAssertTrue(
            Bitkit.AppError(message: "Firmware error", debugMessage: "Device error (code 99): Firmware error").isHwFirmwareError()
        )
        XCTAssertFalse(JadeError.InvalidPin.isHwFirmwareError())
        XCTAssertFalse(TrezorError.Timeout.isHwFirmwareError())
    }

    func testHwSessionFailureCoversBothVendors() {
        XCTAssertTrue(JadeError.Timeout.isHwSessionFailure())
        XCTAssertTrue(Bitkit.AppError(error: JadeError.TransportError(errorDetails: "link lost")).isHwSessionFailure())
        XCTAssertTrue(TrezorError.DeviceDisconnected.isHwSessionFailure())
        XCTAssertTrue(Bitkit.AppError(error: TrezorError.ProtocolError(errorDetails: "THP decryption error")).isHwSessionFailure())
        XCTAssertFalse(JadeError.InvalidPin.isHwSessionFailure())
        XCTAssertFalse(JadeError.AddressMismatch(expected: "a", returned: "b").isHwSessionFailure())
        XCTAssertFalse(TrezorError.ProtocolError(errorDetails: "Invalid PSBT").isHwSessionFailure())
    }

    func testBusyVendorNamesTheBusyDevice() {
        XCTAssertEqual(JadeError.DeviceBusy.hwBusyVendor, .blockstream)
        XCTAssertEqual(Bitkit.AppError(error: JadeError.DeviceLocked).hwBusyVendor, .blockstream)
        XCTAssertEqual(TrezorError.DeviceBusy.hwBusyVendor, .trezor)
        XCTAssertEqual(Bitkit.AppError(error: TrezorError.DeviceBusy).hwBusyVendor, .trezor)
        XCTAssertNil(JadeError.Timeout.hwBusyVendor)
        XCTAssertNil(TrezorError.Timeout.hwBusyVendor)
        XCTAssertNil(Bitkit.AppError(message: "sign failed", debugMessage: nil).hwBusyVendor)
        XCTAssertNil(CancellationError().hwBusyVendor)
    }
}
