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

    func testElectrumConnectPrefixIsDefiniteConnectFailureInAnyCase() {
        for details in ["Failed to connect to Electrum: offline", "FAILED TO CONNECT TO ELECTRUM: timed out"] {
            let error = BroadcastError.ElectrumError(errorDetails: details)
            XCTAssertTrue(error.isDefiniteElectrumConnectFailure(), details)
            XCTAssertTrue(Bitkit.AppError(error: error).isDefiniteElectrumConnectFailure(), details)
        }
    }

    func testOtherFailuresAreNotDefiniteConnectFailures() {
        let errors: [Error] = [
            BroadcastError.ElectrumError(errorDetails: "offline"),
            BroadcastError.ElectrumError(errorDetails: "timeout"),
            BroadcastError.ElectrumError(errorDetails: "Broadcast failed: Failed to connect to Electrum: offline"),
            BroadcastError.ElectrumError(errorDetails: "Broadcast failed: min relay fee not met"),
            BroadcastError.TaskError(errorDetails: "Failed to connect to Electrum: offline"),
            BroadcastError.InvalidHex(errorDetails: "Failed to connect to Electrum: offline"),
            BroadcastError.InvalidTransaction(errorDetails: "Failed to connect to Electrum: offline"),
            Bitkit.AppError(error: BroadcastError.ElectrumError(errorDetails: "response lost")),
            Bitkit.AppError(message: "Failed to connect to Electrum: offline", debugMessage: nil),
        ]
        for error in errors {
            XCTAssertFalse(error.isDefiniteElectrumConnectFailure(), "\(error)")
        }
    }
}
