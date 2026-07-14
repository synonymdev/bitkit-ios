@testable import Bitkit
import BitkitCore
import XCTest

final class BroadcastConnectivityTests: XCTestCase {
    func testElectrumConnectFailureIsConnectivityFailure() {
        XCTAssertTrue(
            BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")
                .isBroadcastConnectivityFailure()
        )
    }

    func testElectrumOfflineDetailsAreConnectivityFailure() {
        XCTAssertTrue(BroadcastError.ElectrumError(errorDetails: "offline").isBroadcastConnectivityFailure())
    }

    func testElectrumBroadcastRejectionIsNotConnectivityFailure() {
        XCTAssertFalse(
            BroadcastError.ElectrumError(errorDetails: "Broadcast failed: bad-txns-inputs-missingorspent")
                .isBroadcastConnectivityFailure()
        )
    }

    func testWrappedElectrumConnectFailureIsConnectivityFailure() {
        let error = Bitkit.AppError(error: BroadcastError.ElectrumError(errorDetails: "offline"))
        XCTAssertTrue(error.isBroadcastConnectivityFailure())
    }

    func testWrappedElectrumBroadcastRejectionIsNotConnectivityFailure() {
        let error = Bitkit.AppError(
            error: BroadcastError.ElectrumError(errorDetails: "Broadcast failed: min relay fee not met")
        )
        XCTAssertFalse(error.isBroadcastConnectivityFailure())
    }

    func testUnrelatedErrorIsNotConnectivityFailure() {
        XCTAssertFalse(Bitkit.AppError(message: "nope", debugMessage: nil).isBroadcastConnectivityFailure())
    }
}
