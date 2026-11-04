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

    func testHardwareRefusalsReadCoreAndServerEnvelopes() {
        let refusals = [
            "Broadcast failed: min relay fee not met, 100 < 141",
            "Broadcast failed: sendrawtransaction RPC error -26: mempool min fee not met, 141 < 2000",
            #"Broadcast failed: Electrum server error: {"code":-26,"message":"txn-mempool-conflict"}"#,
            "Broadcast failed: The transaction was rejected by network rules.\n\nbad-txns-inputs-missingorspent\n[tx]",
        ]
        for details in refusals {
            let error = BroadcastError.ElectrumError(errorDetails: details)
            XCTAssertTrue(error.isHardwareBroadcastRefusal(), details)
            XCTAssertTrue(Bitkit.AppError(error: error).isHardwareBroadcastNotSent(), details)
        }
        XCTAssertFalse(BroadcastError.ElectrumError(errorDetails: "Broadcast failed: connection reset by peer").isHardwareBroadcastRefusal())
        XCTAssertTrue(BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline").isHardwareBroadcastNotSent())
        XCTAssertFalse(BroadcastError.ElectrumError(errorDetails: "offline").isHardwareBroadcastNotSent())
    }

    func testOnlyARefusalProvingTheTransactionInvalidMeansItCanNeverConfirm() {
        let neverConfirmable = [
            "mandatory-script-verify-flag-failed (Signature must be zero for failed CHECK(MULTI)SIG operation)",
            "bad-txns-in-belowout, value in (0.0001) < value out (0.0002)",
            "dust",
            "scriptpubkey",
        ]
        for reason in neverConfirmable {
            let error = BroadcastError.ElectrumError(errorDetails: "Broadcast failed: sendrawtransaction RPC error -26: \(reason)")
            XCTAssertTrue(Bitkit.AppError(error: error).isHardwareBroadcastNeverConfirmable(), reason)
        }
        XCTAssertTrue(BroadcastError.InvalidTransaction(errorDetails: "bad bytes").isHardwareBroadcastNeverConfirmable())

        let mayConfirm = [
            "min relay fee not met, 100 < 141",
            "mempool min fee not met, 141 < 2000",
            "mempool full",
            "too-long-mempool-chain, too many unconfirmed ancestors [limit: 25]",
            "max-fee-exceeded, Fee exceeds maximum configured by user",
            "txn-mempool-conflict",
            "non-mandatory-script-verify-flag (Witness program hash mismatch)",
            "bad-txns-inputs-missingorspent",
        ]
        for reason in mayConfirm {
            let error = BroadcastError.ElectrumError(errorDetails: "Broadcast failed: sendrawtransaction RPC error -26: \(reason)")
            XCTAssertFalse(error.isHardwareBroadcastNeverConfirmable(), reason)
        }
        XCTAssertFalse(BroadcastError.ElectrumError(errorDetails: "Broadcast failed: Electrum server error: <html>")
            .isHardwareBroadcastNeverConfirmable())
        XCTAssertTrue(
            BroadcastError.ElectrumError(errorDetails: "Broadcast failed: sendrawtransaction RPC error -25: bad-txns-inputs-missingorspent")
                .isHardwareBroadcastInputsMissing()
        )
    }
}
