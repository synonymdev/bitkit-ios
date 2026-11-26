@testable import Bitkit
import XCTest

final class SparkExitFundingReleaseTests: XCTestCase {
    private let fundingAddress = "bcrt1qexitfunding"
    private let candidate = String(repeating: "ab", count: 32)

    private func attempt(to address: String? = nil, status: OnchainSendAttempt.Status = .unknown) -> OnchainSendAttempt {
        var attempt = OnchainSendAttempt(
            id: UUID(), walletId: "node:regtest:default:0", requestId: nil, orderId: nil, address: address ?? fundingAddress,
            amountSats: 5000, isMaxAmount: false, status: status, txid: candidate
        )
        attempt.recoveryContext = OnchainSendRecoveryContext(
            inputs: [OnchainSendInput(txid: String(repeating: "ef", count: 32), vout: 0)], satsPerVbyte: 2, paymentIdentity: nil,
            candidateTxids: [candidate]
        )
        return attempt
    }

    private func record(_ phase: SparkExitRecord.Phase, fundingTxid: String? = nil) -> SparkExitRecord {
        SparkExitRecord(
            network: "regtest", createdAt: Date(), phase: phase, feeRateSatPerVbyte: 2, destination: "bcrt1qdestination",
            leafIds: ["leaf-1"],
            funding: [.init(index: 0, address: fundingAddress, pubkey: "02", txid: fundingTxid, vout: fundingTxid == nil ? nil : 0,
                            valueSats: fundingTxid == nil ? nil : 5000)],
            expectedSats: 1000
        )
    }

    private func utxo(_ txid: String) -> EsploraUtxo {
        EsploraUtxo(txid: txid, vout: 0, value: 6000, status: EsploraTxStatus(confirmed: false))
    }

    func testSendPendingNeverRetriesAnExitFunding() {
        let send = attempt()
        XCTAssertTrue(SendPendingScreen.offersRetry(send, isSparkExitFunding: false))
        XCTAssertFalse(SendPendingScreen.offersRetry(send, isSparkExitFunding: true), "The exit's Progress owns its funding")
        XCTAssertEqual(SendPendingScreen.abandonNoteKey(send), "wallet__onchain_abandon_exit_note")
    }

    func testPayingAgainOnlyWhileTheExitStillAsksAndNothingArrived() {
        let send = attempt()
        let asking = SparkExitFundingRelease.Exit(record: record(.awaitingFunding(requiredSats: 5000)), earlier: [])
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: []))
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [utxo(String(repeating: "f1", count: 32))]),
                       "Funding from another wallet reached the address")
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: nil), "The address could not be read")

        var awaiting = record(.awaitingFunding(requiredSats: 5000))
        awaiting.fundingPaymentTxid = candidate
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: awaiting, earlier: []), utxos: []))
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: awaiting, earlier: []),
                                                           utxos: [utxo(String(repeating: "f1", count: 32))]),
                       "Another wallet funded the address")
        awaiting.fundingPaymentTxid = String(repeating: "f1", count: 32)
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: awaiting, earlier: []), utxos: []))

        let funded = SparkExitFundingRelease.Exit(record: record(.running, fundingTxid: String(repeating: "f1", count: 32)), earlier: [])
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: funded, utxos: []))
        let cancelled = SparkExitFundingRelease.Exit(
            record: nil, earlier: [.init(address: fundingAddress, path: "m/0", kind: .cancelledFunding, date: Date())]
        )
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: cancelled, utxos: []))
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(attempt(to: "bcrt1qordinary"), exit: funded, utxos: nil),
                      "A send to no exit's address is not refused")
    }
}
