@testable import Bitkit
import BitkitCore
import XCTest

final class BroadcastConnectivityTests: XCTestCase {
    func testElectrumBroadcastErrorIsConnectivityFailure() {
        XCTAssertTrue(BroadcastError.ElectrumError(errorDetails: "offline").isBroadcastConnectivityFailure())
    }

    func testWrappedElectrumBroadcastErrorIsConnectivityFailure() {
        let error = Bitkit.AppError(error: BroadcastError.ElectrumError(errorDetails: "offline"))
        XCTAssertTrue(error.isBroadcastConnectivityFailure())
    }

    func testUnrelatedErrorIsNotConnectivityFailure() {
        XCTAssertFalse(Bitkit.AppError(message: "nope", debugMessage: nil).isBroadcastConnectivityFailure())
    }
}
