@testable import Bitkit
import XCTest

final class SparkExitFundingReleaseTests: XCTestCase {
    private let fundingAddress = "bcrt1qexitfunding"
    private let candidate = String(repeating: "ab", count: 32)

    private func attempt(
        to address: String? = nil, status: OnchainSendAttempt.Status = .unknown, walletId: String = "node:regtest:default:0"
    ) -> OnchainSendAttempt {
        var attempt = OnchainSendAttempt(
            id: UUID(), walletId: walletId, requestId: nil, orderId: nil, address: address ?? fundingAddress,
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

    private func utxo(_ txid: String, value: UInt64 = 6000) -> EsploraUtxo {
        EsploraUtxo(txid: txid, vout: 0, value: value, status: EsploraTxStatus(confirmed: false))
    }

    func testSendPendingRetriesAnExitFundingUntilItsReleaseIsOffered() {
        let send = attempt()
        XCTAssertTrue(SendPendingScreen.offersRetry(send, isSparkExitFunding: false, releaseOffered: false))
        XCTAssertTrue(SendPendingScreen.offersRetry(send, isSparkExitFunding: true, releaseOffered: false),
                      "An unresolved exit funding is never left without a way out")
        XCTAssertFalse(SendPendingScreen.offersRetry(send, isSparkExitFunding: true, releaseOffered: true), "The release takes its place")
        XCTAssertEqual(SendPendingScreen.abandonNoteKey(send), "wallet__onchain_abandon_exit_note")
    }

    func testPayingAgainOnlyWhileTheExitStillAsks() {
        let send = attempt()
        let asking = SparkExitFundingRelease.Exit(record: record(.awaitingFunding(requiredSats: 5000)), earlier: [])
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: []))
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [utxo(String(repeating: "f1", count: 32))]),
                       "Funding from another wallet covered it")
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [utxo(String(repeating: "f1", count: 32), value: 1000)]),
                      "A partial payment from another wallet still leaves the ask")
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [utxo(candidate)]), "Its own coin covers it: a bump")
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [utxo(candidate), utxo(String(repeating: "f1", count: 32))]),
                       "Others alone cover it")
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: nil), "The address could not be read")

        var awaiting = record(.awaitingFunding(requiredSats: 5000))
        awaiting.fundingPaymentTxid = candidate
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: awaiting, earlier: []), utxos: []))
        XCTAssertTrue(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: awaiting, earlier: []),
                                                          utxos: [utxo(String(repeating: "f1", count: 32), value: 1000)]),
                      "It waits for this payment, which a retry only re-signs")
        let covering = utxo(String(repeating: "f1", count: 32))
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: awaiting, earlier: []), utxos: [covering]),
                       "Another wallet covered it")
        var otherPayment = record(.awaitingFunding(requiredSats: 5000))
        otherPayment.fundingPaymentTxid = String(repeating: "f2", count: 32)
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: .init(record: otherPayment, earlier: []), utxos: []),
                       "It waits for another payment")
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [utxo(candidate, value: 100), covering]),
                       "Others alone cover it")
        let confirmed = EsploraUtxo(txid: candidate, vout: 0, value: 6000, status: EsploraTxStatus(confirmed: true))
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(send, exit: asking, utxos: [confirmed]), "Its own coin confirmed")
        var approved = send
        approved.releaseApproved = true
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(approved, exit: asking, utxos: []), "Its release is Send Pending's to finish")
        XCTAssertFalse(SparkExitFundingRelease.mayPayAgain(approved, exit: .init(record: nil, earlier: []), utxos: []),
                       "Not even once the exit's record is gone")
        XCTAssertFalse(SendPendingScreen.offersRetry(approved, isSparkExitFunding: true, releaseOffered: false))
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

    func testPayingAgainIsRefusedWhenTheFundingAddressCannotBeRead() async throws {
        let asking = SparkExitFundingRelease.Exit(record: record(.awaitingFunding(requiredSats: 5000)), earlier: [])
        do {
            try await SparkExitFundingRelease.authorizePayAgain(attempt(), exit: asking, chain: nil)
            XCTFail("Paid again without reading the funding address")
        } catch {}
        try await SparkExitFundingRelease.authorizePayAgain(attempt(to: "bcrt1qordinary"), exit: asking, chain: nil)
    }

    func testAnUnreadableEarlierAddressListStillReadsTheExit() throws {
        let walletIndex = LightningService.shared.currentWalletIndex
        let store = SparkExitEarlierAddressStore(walletIndex: walletIndex)
        defer { try? store.delete() }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        let send = attempt(to: "bcrt1qordinary", walletId: OnchainSendAttemptService.walletId(index: walletIndex))

        let exit = try XCTUnwrap(SparkExitFundingRelease.storedExit(for: send), "An ordinary send's Retry is never refused for it")
        XCTAssertEqual(exit.earlier, [])
    }
}
