@testable import Bitkit
import BitkitCore
import XCTest

/// `HwErrorPresenter` gives every Jade error Jade or neutral copy and leaves the rest to the Trezor
/// rules. `AppError` is qualified as `Bitkit.AppError` because `Errors.swift` is also compiled into this
/// test target, so an unqualified name would resolve to the duplicate and fail the cast.
final class HwErrorPresenterTests: XCTestCase {
    func testMapsTypedJadeErrorsToTheirMessages() {
        let expectations: [(JadeError, String)] = [
            (.InvalidPin, t("hardware__jade_invalid_pin")),
            (.DeviceUninitialized, t("hardware__jade_uninitialized")),
            (.UnsupportedFirmware(installed: "0.1.0", required: "1.0.34"), t("hardware__jade_firmware_outdated")),
            (.PsbtTooLarge(size: 20000, max: 16384), t("hardware__jade_psbt_too_large")),
            (.NetworkMismatch(errorDetails: "testnet"), t("hardware__jade_network_mismatch")),
            (.DeviceBusy, t("hardware__jade_device_busy")),
            (.DeviceLocked, t("hardware__jade_device_busy")),
            (.PinServerError(errorDetails: "unreachable"), t("hardware__jade_pinserver_error")),
            (.AddressMismatch(expected: "bc1qexpected", returned: "bc1qreturned"), t("hardware__verify_address_error")),
        ]

        for (error, message) in expectations {
            XCTAssertEqual(HwErrorPresenter.userMessage(from: error), message, "\(error)")
            XCTAssertEqual(HwErrorPresenter.jadeMessage(from: error), message, "\(error)")
        }
    }

    func testMapsAWrappedJadeError() {
        XCTAssertEqual(HwErrorPresenter.userMessage(from: Bitkit.AppError(error: JadeError.InvalidPin)), t("hardware__jade_invalid_pin"))
        XCTAssertEqual(
            HwErrorPresenter.userMessage(from: Bitkit.AppError(error: JadeError.PinServerError(errorDetails: "x"))),
            t("hardware__jade_pinserver_error")
        )
    }

    func testTransportAndConnectionDetailsPassThrough() {
        let staleBond = "Bluetooth pairing is no longer valid: forget the Jade in the iOS Bluetooth settings and pair it again."

        XCTAssertEqual(HwErrorPresenter.userMessage(from: JadeError.TransportError(errorDetails: staleBond)), staleBond)
        XCTAssertEqual(HwErrorPresenter.userMessage(from: Bitkit.AppError(error: JadeError.TransportError(errorDetails: "stale text"))), "stale text")
        XCTAssertEqual(HwErrorPresenter.userMessage(from: JadeError.ConnectionError(errorDetails: "Jade refused")), "Jade refused")
    }

    func testBlankDetailsAndOtherJadeErrorsGiveTheConnectError() {
        let connectError = t("hardware__connect_error")
        let errors: [JadeError] = [
            .TransportError(errorDetails: ""),
            .TransportError(errorDetails: "  \n"),
            .ConnectionError(errorDetails: ""),
            .Timeout,
            .DeviceDisconnected,
            .NotConnected,
            .UserCancelled,
            .NothingSigned,
            .ProtocolError(errorDetails: "Device disconnected"),
        ]

        for error in errors {
            XCTAssertEqual(HwErrorPresenter.userMessage(from: error), connectError, "\(error)")
            XCTAssertEqual(HwErrorPresenter.userMessage(from: Bitkit.AppError(error: error)), connectError, "\(error)")
        }
    }

    func testFallsBackToTheTrezorRulesForOtherErrors() {
        XCTAssertEqual(HwErrorPresenter.userMessage(from: TrezorError.DeviceBusy), t("hardware__device_busy"))
        XCTAssertEqual(HwErrorPresenter.userMessage(from: Bitkit.AppError(error: TrezorError.DeviceBusy)), t("hardware__device_busy"))
        XCTAssertEqual(HwErrorPresenter.userMessage(from: Bitkit.AppError(message: "boom", debugMessage: nil)), "boom")
    }

    func testJadeMessageIsNilWithoutAJadeError() {
        XCTAssertNil(HwErrorPresenter.jadeMessage(from: TrezorError.DeviceBusy))
        XCTAssertNil(HwErrorPresenter.jadeMessage(from: Bitkit.AppError(message: "boom", debugMessage: nil)))
        XCTAssertNil(HwErrorPresenter.jadeMessage(from: CancellationError()))
    }

    func testDeviceBusyMessageNamesTheVendor() {
        XCTAssertEqual(HwErrorPresenter.deviceBusyMessage(for: .trezor), t("hardware__device_busy"))
        XCTAssertEqual(HwErrorPresenter.deviceBusyMessage(for: .blockstream), t("hardware__jade_device_busy"))
        XCTAssertNotEqual(HwErrorPresenter.deviceBusyMessage(for: .trezor), HwErrorPresenter.deviceBusyMessage(for: .blockstream))
    }
}
