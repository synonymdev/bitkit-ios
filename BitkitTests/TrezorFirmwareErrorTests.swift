@testable import Bitkit
import BitkitCore
import XCTest

final class TrezorFirmwareErrorTests: XCTestCase {
    func testFirmwareErrorRecognizedFromAppErrorMessage() {
        let error = Bitkit.AppError(
            message: "Firmware error",
            debugMessage: "Device error (code 99): Firmware error"
        )
        XCTAssertTrue(error.isTrezorFirmwareError())
    }

    func testFirmwareErrorRejectsUnrelatedMessages() {
        XCTAssertFalse(Bitkit.AppError(message: "Firmware error", debugMessage: nil).isTrezorFirmwareError())
        XCTAssertFalse(
            Bitkit.AppError(message: "x", debugMessage: "Device error (code 98): Firmware error").isTrezorFirmwareError()
        )
    }
}
