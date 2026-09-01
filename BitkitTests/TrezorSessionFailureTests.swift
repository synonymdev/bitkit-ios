@testable import Bitkit
import BitkitCore
import XCTest

final class TrezorSessionFailureTests: XCTestCase {
    func testRecognizesWrappedChannelMismatch() {
        let error = Bitkit.AppError(
            error: TrezorError.ProtocolError(
                errorDetails: "THP decryption error: Channel mismatch: expected [73, cb], got [73, ca]"
            )
        )

        XCTAssertTrue(error.isTrezorSessionFailure())
    }

    func testRejectsUnrelatedProtocolFailure() {
        XCTAssertFalse(TrezorError.ProtocolError(errorDetails: "Invalid PSBT").isTrezorSessionFailure())
    }
}
