@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

/// Device-signing orchestration coverage for `HwFundingSigner`, exercised in isolation from
/// `TransferViewModel` via the `HwTransferFunding` / `HwTransferConnecting` mocks.
@MainActor
final class HwFundingSignerTests: XCTestCase {
    private var heldDefaults: UserDefaults!
    private var heldResolver: FakeHeldBroadcastResolver!
    private var heldBroadcasts: HwHeldBroadcastStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        heldDefaults = try makeIsolatedDefaults()
        heldResolver = FakeHeldBroadcastResolver()
        heldBroadcasts = HwHeldBroadcastStore(defaults: heldDefaults, resolver: heldResolver)
    }

    /// A coordinator that holds its sends in a store of its own, never in the app's defaults. Coordinators that stand for
    /// sheets sharing one app pass `heldBroadcasts`.
    private func makeCoordinator(
        walletId: String? = nil,
        signerFactory: (@MainActor (HwWalletManager, String, UInt64) -> HwFundingSigner)? = nil,
        heldBroadcasts: HwHeldBroadcastStore? = nil,
        broadcastDeadline: Duration = .seconds(60)
    ) -> HwSendCoordinator {
        let store = heldBroadcasts ?? {
            let suiteName = "HwFundingSignerTests.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
            return HwHeldBroadcastStore(defaults: UserDefaults(suiteName: suiteName)!, resolver: FakeHeldBroadcastResolver())
        }()
        guard let signerFactory else {
            return HwSendCoordinator(walletId: walletId, heldBroadcasts: store, broadcastDeadline: broadcastDeadline)
        }
        return HwSendCoordinator(
            walletId: walletId, signerFactory: signerFactory, heldBroadcasts: store, broadcastDeadline: broadcastDeadline
        )
    }

    private func paymentRequestRecord(
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        paymentProofs: [PaymentProofRecord] = [],
        paymentRequestId: String = "550e8400-e29b-41d4-a716-446655440000",
        state: PaymentRequestLifecycleState = .proposed,
        recurrence: PaymentRequestRecurrence? = nil
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: "pubky" + String(repeating: "y", count: 52),
            paymentRequestId: paymentRequestId,
            localRole: .payer,
            state: state,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            proposalAppId: "bitkit",
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.00001", asset: "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: recurrence,
                acceptedPaymentEndpointIdentifiers: endpoints,
                paymentEndpoints: nil,
                requiredAppId: "bitkit",
                conversion: nil,
                paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
            paymentProofs: paymentProofs,
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
    }

    /// A signed transaction whose txid is `signedTransactionId`.
    private static let signedTransactionHex =
        "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"
    private static let signedTransactionId = "605fe246a6d51450ecff51ac3d0415f8824964e06a60ed6e186fa163cf1e9d4e"

    private func makeSigner(
        funding: MockHwFunding,
        connecting: MockHwConnecting,
        feeRate: UInt64? = 2,
        address: String? = "bc1qtest",
        timeouts: (compose: Double, sign: Double) = (compose: 5, sign: 5)
    ) -> HwFundingSigner {
        HwFundingSigner(
            funding: funding,
            connecting: connecting,
            feeRateProvider: { feeRate },
            addressProvider: {
                if let address {
                    return address
                } else {
                    throw MockHwFunding.TestError()
                }
            },
            timeouts: timeouts
        )
    }

    // MARK: - Fee reserve (fallback math)

    func testFeeReserveUsesRateWhenAvailable() {
        XCTAssertEqual(HwFundingSigner.feeReserve(balanceSats: 1_000_000, satsPerVByte: 5), 5 * 1200)
    }

    func testFeeReserveFallbackUsesPercentWhenLarger() {
        // 10% of 1,000,000 = 100,000 dominates the 1,200 sat floor.
        XCTAssertEqual(HwFundingSigner.feeReserve(balanceSats: 1_000_000, satsPerVByte: nil), 100_000)
    }

    func testFeeReserveFallbackUsesFloorWhenPercentSmaller() {
        // 10% of 5,000 = 500, below the 3 * 1200 floor.
        XCTAssertEqual(HwFundingSigner.feeReserve(balanceSats: 5000, satsPerVByte: nil), 3600)
    }

    func testCoordinatorChangesFundingWalletAndClearsDevicePrompt() {
        let coordinator = makeCoordinator()
        coordinator.requestPassphrase()

        coordinator.selectWallet("trezor:wallet", initialAvailableSats: 42000)

        XCTAssertEqual(coordinator.walletId, "trezor:wallet")
        XCTAssertEqual(coordinator.availableSats, 42000)
        XCTAssertTrue(coordinator.isActive)
        XCTAssertFalse(coordinator.isPassphraseRequired)

        coordinator.selectWallet(nil)

        XCTAssertFalse(coordinator.isActive)
    }

    func testCoordinatorSeedsAvailableForSelectedWalletOnly() {
        let coordinator = makeCoordinator(walletId: "trezor:selected")

        coordinator.seedAvailable(walletId: "trezor:other", availableSats: 10000)
        XCTAssertEqual(coordinator.availableSats, 0)

        coordinator.seedAvailable(walletId: "trezor:selected", availableSats: 42000)
        XCTAssertEqual(coordinator.availableSats, 42000)
    }

    func testCoordinatorTracksFundingSourceRefresh() async {
        let funding = MockHwFunding()
        funding.maxSpendable = 42000
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: MockHwConnecting(),
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        coordinator.selectWallet("trezor:wallet", showsLoading: true)

        XCTAssertTrue(coordinator.isFundingSourceLoading)
        await coordinator.refreshAvailable(
            manager: manager,
            destinationAddress: "bc1qtest",
            satsPerVByte: 2
        )
        XCTAssertFalse(coordinator.isFundingSourceLoading)
        XCTAssertEqual(coordinator.availableSats, 42000)
    }

    func testCoordinatorSettlesFundingSourceLoadingWithoutFeeRate() async {
        let manager = HwWalletManager()
        let coordinator = makeCoordinator()
        coordinator.selectWallet(
            "trezor:wallet",
            initialAvailableSats: 42000,
            showsLoading: true
        )

        await coordinator.refreshAvailable(
            manager: manager,
            destinationAddress: "bc1qtest",
            satsPerVByte: nil
        )

        XCTAssertFalse(coordinator.isFundingSourceLoading)
        XCTAssertEqual(coordinator.availableSats, 42000)
    }

    func testCoordinatorTracksPreviewPreparation() async throws {
        let funding = MockHwFunding()
        funding.estimateDelay = 0.05
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: MockHwConnecting(),
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        coordinator.selectWallet("trezor:wallet", showsLoading: true)

        let preview = Task {
            try await coordinator.preparePreview(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2
            )
        }
        await Task.yield()

        XCTAssertTrue(coordinator.isFundingSourceLoading)
        XCTAssertTrue(coordinator.isPreviewLoading)
        XCTAssertEqual(coordinator.previewFeeSats, 0)
        _ = try await preview.value
        XCTAssertFalse(coordinator.isFundingSourceLoading)
        XCTAssertFalse(coordinator.isPreviewLoading)
        XCTAssertEqual(coordinator.previewFeeSats, funding.funding.miningFeeSats)
    }

    func testCoordinatorSettlesLoadingWhenPreviewFails() async {
        let funding = MockHwFunding()
        funding.composeError = MockHwFunding.TestError()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: MockHwConnecting(),
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        coordinator.selectWallet("trezor:wallet", showsLoading: true)

        do {
            _ = try await coordinator.preparePreview(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2
            )
            XCTFail("Expected preview preparation to fail")
        } catch {
            XCTAssertTrue(error is MockHwFunding.TestError)
        }

        XCTAssertFalse(coordinator.isFundingSourceLoading)
        XCTAssertFalse(coordinator.isPreviewLoading)
        XCTAssertEqual(coordinator.previewFeeSats, 0)
    }

    func testAPlainSendWhoseBroadcastOutcomeIsUnknownIsHeldAndNeverSignedAgain() async throws {
        let unknownOutcomes: [Error] = [
            BroadcastError.ElectrumError(errorDetails: "Broadcast failed: connection reset by peer"),
            BroadcastError.ElectrumError(errorDetails: "offline"),
            BroadcastError.TaskError(errorDetails: "task failed"),
            MockHwFunding.TestError(),
        ]
        for error in unknownOutcomes {
            let funding = MockHwFunding()
            funding.signedTx = heldSignedTx
            funding.broadcastError = error
            let coordinator = try makeCoordinator(
                walletId: "trezor:wallet",
                signerFactory: signerFactory(funding),
                heldBroadcasts: HwHeldBroadcastStore(defaults: makeIsolatedDefaults(), resolver: FakeHeldBroadcastResolver())
            )

            await assertThrowsAsync { try await self.send(coordinator) }
            XCTAssertEqual(coordinator.unresolvedSend?.txId, Self.signedTransactionId, "\(error)")
            XCTAssertTrue(coordinator.isBroadcastUnresolved, "\(error)")
            XCTAssertFalse(coordinator.canLeave, "\(error)")
            coordinator.cancel()
            XCTAssertTrue(coordinator.hasPendingBroadcast, "Leaving keeps the signed transaction: \(error)")
            funding.broadcastError = nil
            await assertThrowsAsync { try await self.send(coordinator) } _: { retryError in
                XCTAssertEqual(retryError as? HwTransferError, .broadcastUncertain, "\(error)")
            }

            XCTAssertEqual(funding.signCalls, 1, "\(error)")
            XCTAssertEqual(funding.broadcastCalls, 2, "A retry broadcasts the same bytes again: \(error)")
            XCTAssertEqual(Set(funding.broadcastTransactions), [Self.signedTransactionHex], "\(error)")
            XCTAssertNotNil(coordinator.unresolvedSend, "An accepted rebroadcast stays pending until the wallet sees it: \(error)")
        }
    }

    func testAHeldSendIsNeverSignedAgainFromAnotherSheetUntilItIsResolved() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        func openSheet() -> HwSendCoordinator {
            makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        }

        // Held from before the broadcast, as the app can be killed while it runs
        let gate = AsyncGate()
        funding.broadcastGate = gate
        let first = openSheet()
        let broadcast = Task { try await self.send(first) }
        await eventually("the broadcast started") { funding.broadcastCalls == 1 }
        let duringBroadcast = openSheet()
        let refused = Task { try await self.send(duringBroadcast) }
        await eventually("the second sheet is refused or signs") { duringBroadcast.unresolvedSend != nil || funding.signCalls > 1 }
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(duringBroadcast.unresolvedSend?.txId, Self.signedTransactionId)
        funding.broadcastError = MockHwFunding.TestError()
        gate.open()
        _ = await broadcast.result
        if case .success = await refused.result {
            XCTFail("The second sheet sent the payment again")
        }
        funding.broadcastGate = nil

        let reopened = openSheet()
        await assertThrowsAsync { try await self.send(reopened) }
        XCTAssertEqual(reopened.unresolvedSend?.txId, Self.signedTransactionId)
        XCTAssertFalse(reopened.canLeave)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(Set(funding.broadcastTransactions), [Self.signedTransactionHex], "Only the held bytes are ever broadcast")
        funding.broadcastError = nil

        funding.signedTx = HwFundingSignedTx(serializedTx: "othertx", miningFeeSats: 141, feeRate: 2, totalSpent: 42141)
        try await send(openSheet(), sats: 41000)
        XCTAssertEqual(funding.signCalls, 2, "Another payment is not held back")
        await assertThrowsAsync { try await self.send(openSheet(), address: "BC1QTEST") }
        XCTAssertEqual(funding.signCalls, 2, "The address of a held send matches whatever its case")

        heldResolver.observed = [heldSignedTx.serializedTx]
        let seen = openSheet()
        await assertThrowsAsync { try await self.send(seen) }
        XCTAssertEqual(funding.signCalls, 2, "A seen payment is completed rather than signed again")
        _ = await seen.completeObservedSend { _ in }
        try await send(openSheet())
        XCTAssertEqual(funding.signCalls, 3, "Once the seen payment is recorded, a new one can be made")
    }

    func testARetriedHeldSendThatCanNeverConfirmIsReleasedAndSignedAfresh() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        funding.broadcastError = MockHwFunding.TestError()
        try await holdUnknownSend(funding)

        funding.broadcastError = refusal("mandatory-script-verify-flag-failed (Signature must be zero for failed CHECK(MULTI)SIG operation)")
        let retry = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        await assertThrowsAsync { try await self.send(retry) } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastNeverConfirms)
        }
        XCTAssertEqual(funding.signCalls, 1, "A rebroadcast never signs")
        XCTAssertEqual(retry.releasedSendTxId, Self.signedTransactionId)
        XCTAssertNil(retry.unresolvedSend)
        XCTAssertTrue(retry.canLeave)
        let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertNil(held)

        funding.broadcastError = nil
        try await send(retry)
        XCTAssertEqual(funding.signCalls, 2, "A payment that can never confirm can be made again")
    }

    func testARebroadcastRefusalThatLeavesAValidTransactionKeepsTheHold() async throws {
        let validRefusals: [Error] = [
            refusal("min relay fee not met, 100 < 141"),
            refusal("mempool min fee not met, 141 < 2000"),
            refusal("mempool full"),
            refusal("too-long-mempool-chain, too many unconfirmed ancestors [limit: 25]"),
            refusal("txn-mempool-conflict"),
            refusal("bad-txns-inputs-missingorspent"),
            BroadcastError.ElectrumError(errorDetails: "Broadcast failed: Electrum server error: <html>bad gateway</html>"),
            refusal("max-fee-exceeded, Fee exceeds maximum configured by user"),
            BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline"),
            MockHwFunding.TestError(),
        ]
        for error in validRefusals {
            try setUpWithError()
            let funding = MockHwFunding()
            funding.signedTx = heldSignedTx
            funding.broadcastError = MockHwFunding.TestError()
            let coordinator = try await holdUnknownSend(funding)

            funding.broadcastError = error
            let outcome = await coordinator.rebroadcastUnresolvedSend(manager: HwWalletManager())

            XCTAssertEqual(outcome, .mayConfirm, "\(error)")
            XCTAssertEqual(coordinator.unresolvedSend?.txId, Self.signedTransactionId, "\(error)")
            XCTAssertNil(coordinator.releasedSendTxId, "\(error)")
            let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
            XCTAssertNotNil(held, "\(error)")
            XCTAssertEqual(funding.signCalls, 1, "\(error)")
        }
    }

    func testARefusedCoinReleasesTheHoldOnlyOnceAFreshReadShowsItSpentElsewhere() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        funding.broadcastError = MockHwFunding.TestError()
        let coordinator = try await holdUnknownSend(funding)
        funding.broadcastError = refusal("bad-txns-inputs-missingorspent")

        heldResolver.spentElsewhereError = MockHwFunding.TestError()
        let unreadable = await coordinator.rebroadcastUnresolvedSend(manager: HwWalletManager())
        XCTAssertEqual(unreadable, .mayConfirm, "A failed read proves nothing")

        heldResolver.spentElsewhereError = nil
        heldResolver.spentElsewhere = [heldSignedTx.serializedTx]
        heldResolver.resetObservationCount()
        heldResolver.observedFromCall = 2
        let confirmed = await coordinator.rebroadcastUnresolvedSend(manager: HwWalletManager())
        XCTAssertEqual(confirmed, .accepted, "A transaction the wallet sees after the refusal is never released")
        XCTAssertNotNil(coordinator.unresolvedSend)

        heldResolver.observedFromCall = nil
        let spent = await coordinator.rebroadcastUnresolvedSend(manager: HwWalletManager())
        XCTAssertEqual(spent, .neverConfirms)
        XCTAssertNil(coordinator.unresolvedSend)
        let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertNil(held)
    }

    func testAFirstBroadcastRefusalReleasesTheHoldAsTheTransactionNeverLeft() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        funding.broadcastError = refusal("min relay fee not met, 100 < 141")
        let coordinator = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)

        await assertThrowsAsync { try await self.send(coordinator) }

        XCTAssertNil(coordinator.unresolvedSend)
        let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertNil(held)
    }

    func testABroadcastPastItsDeadlineMovesToPendingAndItsLateAnswerStillLands() async throws {
        for lateAnswer in [nil, BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")] as [Error?] {
            try setUpWithError()
            let funding = MockHwFunding()
            funding.signedTx = heldSignedTx
            let gate = AsyncGate()
            funding.broadcastGate = gate
            let coordinator = makeCoordinator(
                walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts,
                broadcastDeadline: .milliseconds(50)
            )

            await assertThrowsAsync { try await self.send(coordinator) } _: { error in
                XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
            }
            XCTAssertEqual(coordinator.unresolvedSend?.txId, Self.signedTransactionId)
            XCTAssertFalse(coordinator.isSigning, "The sign screen stops waiting")
            let heldDuringBroadcast = try await heldBroadcasts.heldSend(
                walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000
            )
            XCTAssertNotNil(heldDuringBroadcast)

            funding.broadcastError = lateAnswer
            gate.open()
            if lateAnswer == nil {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(coordinator.unresolvedSend?.txId, Self.signedTransactionId, "An accepted send waits for the wallet")
                let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
                XCTAssertNotNil(held)
            } else {
                await eventually("the late refusal released the payment") { coordinator.releasedSendTxId == Self.signedTransactionId }
                XCTAssertNil(coordinator.unresolvedSend)
                XCTAssertTrue(coordinator.canLeave)
                let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
                XCTAssertNil(held)
            }
            XCTAssertEqual(funding.broadcastCalls, 1)
        }
    }

    func testALateNotSentAnswerKeepsTheHoldOnceTheSameBytesWereBroadcastAgain() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        let firstBroadcast = AsyncGate()
        funding.broadcastGateForCall[1] = firstBroadcast
        funding.broadcastErrorForCall[1] = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: reset")
        let coordinator = makeCoordinator(
            walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts,
            broadcastDeadline: .milliseconds(50)
        )
        await assertThrowsAsync { try await self.send(coordinator) }
        XCTAssertEqual(coordinator.unresolvedSend?.txId, Self.signedTransactionId)

        XCTAssertFalse(coordinator.canBroadcastAgain, "Its bytes are not broadcast again while the first broadcast runs")
        let whileRunning = await coordinator.rebroadcastUnresolvedSend(manager: HwWalletManager())
        XCTAssertEqual(whileRunning, .mayConfirm)
        XCTAssertEqual(funding.broadcastCalls, 1)

        // The store refuses a dispatch beside one in flight, for any sheet; here a second dispatch got in and was taken
        let accepted = try XCTUnwrap(heldBroadcasts.beginDispatch(
            HwHeldBroadcast(heldSignedTx, walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000), isRebroadcast: false
        ))
        heldBroadcasts.endDispatch(accepted, isAccepted: true)
        firstBroadcast.open()
        await eventually("the first broadcast answered") { !coordinator.isLateBroadcastRunning }

        XCTAssertNotNil(coordinator.unresolvedSend, "The same bytes were taken, so the payment stays pending")
        XCTAssertNil(coordinator.releasedSendTxId)
        XCTAssertTrue(try heldBroadcasts.isHeld(heldSignedTx), "A late answer for one broadcast proves nothing about another")
    }

    func testANotSentAnswerKeepsTheHoldOnceAnotherSheetBroadcastTheSameBytes() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        let firstBroadcast = AsyncGate()
        funding.broadcastGateForCall[1] = firstBroadcast
        funding.broadcastErrorForCall[1] = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: reset")
        let firstSheet = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        let first = Task { try await self.send(firstSheet) }
        await eventually("the first broadcast started") { funding.broadcastCalls == 1 }

        let secondSheet = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        await assertThrowsAsync { try await self.send(secondSheet) }
        XCTAssertEqual(funding.broadcastCalls, 1, "Another sheet does not broadcast the same bytes while they are in flight")
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertNotNil(secondSheet.unresolvedSend)

        // The second sheet broadcasts once the first answered, and the network takes the bytes
        firstBroadcast.open()
        _ = await first.result
        XCTAssertFalse(try heldBroadcasts.isHeld(heldSignedTx), "Nothing else was sent, so the first answer proves nothing went out")
        let afterRelease = await secondSheet.rebroadcastUnresolvedSend(manager: HwWalletManager())
        XCTAssertEqual(afterRelease, .neverConfirms, "A released send is never broadcast again from a stale sheet")
        XCTAssertEqual(funding.broadcastCalls, 1)

        // With a second dispatch taken while the first was in flight, the first's not-sent answer keeps the hold
        funding.broadcastGateForCall[2] = AsyncGate()
        funding.broadcastErrorForCall[2] = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: reset")
        let thirdSheet = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        let third = Task { try await self.send(thirdSheet) }
        await eventually("the next broadcast started") { funding.broadcastCalls == 2 }
        let held = HwHeldBroadcast(heldSignedTx, walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        let other = try XCTUnwrap(heldBroadcasts.beginDispatch(held, isRebroadcast: false))
        heldBroadcasts.endDispatch(other, isAccepted: true)
        funding.broadcastGateForCall[2]?.open()
        _ = await third.result

        XCTAssertTrue(try heldBroadcasts.isHeld(heldSignedTx))
        XCTAssertEqual(thirdSheet.unresolvedSend?.txId, Self.signedTransactionId, "The payment stays pending")
    }

    func testALateShopSuccessReachesTheProofFlow() async throws {
        let (coordinator, funding, gate, callbacks) = try await startShopPaymentPastItsDeadline(lateError: nil)

        gate.open()
        await eventually("the late success reached the proof flow") { callbacks.completed == [funding.broadcastTxId] }

        XCTAssertEqual(callbacks.refusals, [false])
        XCTAssertTrue(coordinator.isBroadcastUnresolved, "The payment stays uncertain until its proof resolves it")
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertEqual(funding.broadcastCalls, 1)
    }

    func testALateShopRefusalMarksTheRetainedCandidateRefused() async throws {
        let (coordinator, funding, gate, callbacks) = try await startShopPaymentPastItsDeadline(
            lateError: refusal("min relay fee not met, 100 < 141")
        )

        gate.open()
        await eventually("the late refusal marked the candidate") { callbacks.refusals == [false, true] }

        XCTAssertTrue(callbacks.completed.isEmpty)
        XCTAssertFalse(coordinator.isBroadcastUnresolved)
        XCTAssertTrue(coordinator.canLeave)
        XCTAssertTrue(coordinator.hasPendingBroadcast, "The refused candidate stays retained")
        XCTAssertEqual(funding.signCalls, 1)
    }

    private final class ShopCallbacks {
        var completed: [String] = []
        var refusals: [Bool] = []
    }

    private func startShopPaymentPastItsDeadline(
        lateError: Error?
    ) async throws -> (HwSendCoordinator, MockHwFunding, AsyncGate, ShopCallbacks) {
        let funding = MockHwFunding()
        let gate = AsyncGate()
        funding.broadcastGateForCall[1] = gate
        funding.broadcastErrorForCall[1] = lateError
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", signerFactory: signerFactory(funding), broadcastDeadline: .milliseconds(50)
        )
        let callbacks = ShopCallbacks()
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        func pay() async throws {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId,
                markSignedPaymentRefused: { _, refused in callbacks.refusals.append(refused) },
                afterBroadcast: { callbacks.completed.append($0.txId) }
            )
        }

        await assertThrowsAsync { try await pay() } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertFalse(coordinator.isSigning, "The sign screen stops waiting")
        XCTAssertTrue(coordinator.isBroadcastUnresolved)
        XCTAssertFalse(coordinator.canLeave)
        await assertThrowsAsync { try await pay() } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.broadcastCalls, 1, "A retry waits for the running broadcast to answer")
        return (coordinator, funding, gate, callbacks)
    }

    func testASuccessfulSendStaysHeldUntilItIsRecorded() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        let coordinator = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)

        try await send(coordinator)
        let beforeRecord = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertNotNil(beforeRecord, "A send whose activity is not saved yet is still held")

        coordinator.completeBroadcast()
        let afterRecord = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertNil(afterRecord)
    }

    func testARetryThatIsNotDispatchedReleasesItsHold() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")
        let coordinator = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        await assertThrowsAsync { try await self.send(coordinator) }
        XCTAssertTrue(coordinator.hasPendingBroadcast)

        let deadline = PaykitPreciseInstant(date: Date().addingTimeInterval(60))
        funding.broadcastNow = { deadline.date.addingTimeInterval(1) }
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentDeadline: deadline
            )
        }

        let held = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertNil(held, "A retry proven not dispatched leaves no hold")
        XCTAssertEqual(funding.signCalls, 1)
    }

    func testAnUnresolvedSendIsRecordedThenReleasedOnceTheWalletSeesIt() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        funding.broadcastError = MockHwFunding.TestError()
        let coordinator = try await holdUnknownSend(funding)
        coordinator.annotateUnresolvedSend(contactPublicKey: "pubkycontact", tags: ["rent"])
        var recorded: [HwUnresolvedSend] = []

        let unseen = await coordinator.completeObservedSend { recorded.append($0) }
        XCTAssertFalse(unseen)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(coordinator.canLeave)

        heldResolver.observed = [heldSignedTx.serializedTx]
        let seen = await coordinator.completeObservedSend { send in
            recorded.append(send)
            XCTAssertNotNil(self.heldDefaults.data(forKey: "hwHeldBroadcasts"), "The hold outlives the recording")
        }
        let again = await coordinator.completeObservedSend { recorded.append($0) }

        XCTAssertTrue(seen)
        XCTAssertFalse(again)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.txId, Self.signedTransactionId)
        XCTAssertEqual(recorded.first?.address, "bc1qtest")
        XCTAssertEqual(recorded.first?.amountSats, 42000)
        XCTAssertEqual(recorded.first?.contactPublicKey, "pubkycontact")
        XCTAssertEqual(recorded.first?.tags, ["rent"])
        XCTAssertNil(coordinator.unresolvedSend)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        XCTAssertTrue(coordinator.canLeave, "The sheet can be dismissed once the payment completes")
        XCTAssertNil(heldDefaults.data(forKey: "hwHeldBroadcasts"))
    }

    func testAHeldSendOutlivesItsStoreAndIsReportedOnceTheWalletSeesIt() async throws {
        let resolver = FakeHeldBroadcastResolver()
        try HwHeldBroadcastStore(defaults: heldDefaults, resolver: resolver)
            .hold(HwHeldBroadcast(heldSignedTx, walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000))

        let relaunched = HwHeldBroadcastStore(defaults: heldDefaults, resolver: resolver)
        let unresolved = try await relaunched.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertEqual(unresolved, .unresolved(HwHeldBroadcast(heldSignedTx, walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)))
        let otherAmount = try await relaunched.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 41000)
        XCTAssertNil(otherAmount)

        resolver.observedError = MockHwFunding.TestError()
        let unreadable = try await relaunched.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertEqual(unreadable?.held.serializedTx, heldSignedTx.serializedTx, "A failed read keeps the hold")
        resolver.observedError = nil

        resolver.observed = [heldSignedTx.serializedTx]
        let observed = try await relaunched.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertEqual(observed, .observed(HwHeldBroadcast(heldSignedTx, walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)))
        XCTAssertTrue(try relaunched.isHeld(heldSignedTx), "A send the wallet has seen stays held until it is recorded")
    }

    func testARetryOfASendTheWalletHasSeenIsRecordedInsteadOfSignedAgain() async throws {
        let funding = MockHwFunding()
        funding.signedTx = heldSignedTx
        funding.broadcastError = MockHwFunding.TestError()
        try await holdUnknownSend(funding)
        heldResolver.observed = [heldSignedTx.serializedTx]
        funding.broadcastError = nil

        let retry = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        await assertThrowsAsync { try await self.send(retry) } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.signCalls, 1, "A payment the wallet has seen is never signed again")
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(retry.unresolvedSend?.txId, Self.signedTransactionId, "It shows on the pending screen, which completes it")

        retry.annotateUnresolvedSend(contactPublicKey: nil, tags: ["rent"])
        var recorded: [HwUnresolvedSend] = []
        let completed = await retry.completeObservedSend { recorded.append($0) }
        XCTAssertTrue(completed)
        XCTAssertEqual(recorded.map(\.tags), [["rent"]])
        XCTAssertFalse(try heldBroadcasts.isHeld(heldSignedTx))

        try await send(makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts))
        XCTAssertEqual(funding.signCalls, 2, "Only a payment started after it completed is signed")
    }

    func testAnUnreadableHeldStoreRefusesTheSendBeforeSigning() async {
        heldDefaults.set(Data("not json".utf8), forKey: "hwHeldBroadcasts")
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)

        await assertThrowsAsync { try await self.send(coordinator) } _: { error in
            XCTAssertEqual(error as? HwHeldBroadcastStoreError, .unreadable)
        }

        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(funding.broadcastCalls, 0)
    }

    func testAnUnreadableHeldEntryRefusesOnlyItsOwnWalletAndIsKept() async throws {
        try heldBroadcasts.hold(HwHeldBroadcast(heldSignedTx, walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000))
        var entries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(heldDefaults.data(forKey: "hwHeldBroadcasts"))) as? [[String: Any]]
        )
        entries[0]["addedLater"] = "a field from a newer version"
        entries.append(["walletId": "trezor:broken", "serializedTx": 42])
        try heldDefaults.set(JSONSerialization.data(withJSONObject: entries), forKey: "hwHeldBroadcasts")

        let newer = try await heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        XCTAssertEqual(newer?.held.serializedTx, heldSignedTx.serializedTx, "An entry with fields from a newer version still holds")
        await assertThrowsAsync {
            _ = try await self.heldBroadcasts.heldSend(walletId: "trezor:broken", address: "bc1qtest", amountSats: 42000)
        } _: { error in
            XCTAssertEqual(error as? HwHeldBroadcastStoreError, .unreadable)
        }

        try heldBroadcasts.release(heldSignedTx)
        let kept = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(heldDefaults.data(forKey: "hwHeldBroadcasts"))) as? [[String: Any]]
        )
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["walletId"] as? String, "trezor:broken", "An entry that cannot be read is never dropped")

        try heldDefaults.set(JSONSerialization.data(withJSONObject: [["serializedTx": "no wallet"]]), forKey: "hwHeldBroadcasts")
        await assertThrowsAsync {
            _ = try await self.heldBroadcasts.heldSend(walletId: "trezor:wallet", address: "bc1qtest", amountSats: 42000)
        } _: { error in
            XCTAssertEqual(error as? HwHeldBroadcastStoreError, .unreadable, "An entry of an unknown wallet refuses every wallet")
        }
    }

    private var heldSignedTx: HwFundingSignedTx {
        HwFundingSignedTx(serializedTx: Self.signedTransactionHex, miningFeeSats: 141, feeRate: 2, totalSpent: 43186)
    }

    private func signerFactory(_ funding: MockHwFunding) -> @MainActor (HwWalletManager, String, UInt64) -> HwFundingSigner {
        { [self] _, address, rate in
            makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: rate, address: address)
        }
    }

    private func send(_ coordinator: HwSendCoordinator, address: String = "bc1qtest", sats: UInt64 = 42000) async throws {
        _ = try await coordinator.signAndBroadcast(manager: HwWalletManager(), address: address, sats: sats, satsPerVByte: 2)
    }

    /// Sends once so the broadcast outcome is unknown, leaving the send held in this test's store.
    @discardableResult
    private func holdUnknownSend(_ funding: MockHwFunding) async throws -> HwSendCoordinator {
        let coordinator = makeCoordinator(walletId: "trezor:wallet", signerFactory: signerFactory(funding), heldBroadcasts: heldBroadcasts)
        await assertThrowsAsync { try await self.send(coordinator) }
        XCTAssertEqual(coordinator.unresolvedSend?.txId, Self.signedTransactionId)
        return coordinator
    }

    private func refusal(_ reason: String) -> Error {
        BroadcastError.ElectrumError(errorDetails: "Broadcast failed: sendrawtransaction RPC error -26: \(reason)")
    }

    func testCoordinatorRoutesOnlyUnverifiedShopBroadcastToPending() async throws {
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: "merchant", billingPeriodStartsAt: nil
        )
        for (request, verified) in [(Optional(requestId), false), (Optional(requestId), true), (nil, false)] {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let coordinator = makeCoordinator(walletId: "trezor:original-ios-wallet", signerFactory: { [self] _, address, rate in
                makeSigner(funding: funding, connecting: connecting, feeRate: rate, address: address)
            })
            var route: SendRoute?
            var completionTxids: [String] = []
            let result = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qoriginal", sats: 42000, satsPerVByte: 2,
                afterBroadcast: { result in
                    route = await coordinator.completionRoute(
                        result: result, walletId: "trezor:original-ios-wallet", requestId: request, paymentIdentity: "original-payer",
                        completeContactPayment: { txid in
                            completionTxids.append(txid)
                            return verified
                        }
                    )
                }
            )
            if let request, !verified {
                XCTAssertEqual(
                    route,
                    .hardwarePending(
                        requestId: request,
                        walletId: "trezor:original-ios-wallet",
                        transactionId: result.txId,
                        paymentIdentity: "original-payer"
                    )
                )
            } else {
                XCTAssertEqual(route, .success(paymentId: result.txId, walletId: "trezor:original-ios-wallet"))
            }
            XCTAssertEqual(completionTxids, [result.txId])
            XCTAssertEqual(funding.broadcastCalls, 1)
            XCTAssertEqual(funding.signCalls, 1)
        }
    }

    func testCoordinatorRetryReusesSignedPaymentAfterConnectivityFailure() async throws {
        try await assertCoordinatorRetryReusesSignedPayment(
            error: BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")
        )
    }

    func testCoordinatorDeniedRetryPreservesAttemptedPayment() async throws {
        let broadcastErrors: [Error] = [
            BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline"),
        ]

        for broadcastError in broadcastErrors {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(
                walletId: "trezor:original-ios-wallet",
                signerFactory: { [self] _, address, satsPerVByte in
                    makeSigner(
                        funding: funding,
                        connecting: connecting,
                        feeRate: satsPerVByte,
                        address: address
                    )
                }
            )
            let identity = "pubky" + String(repeating: "z", count: 52)
            let request = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(
                endpoints: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue]
            ), now: Date()))
            let store = PaymentProofMemoryStore()
            let sdk = PaymentProofSdkMock(identity: identity, records: [])
            let proofService = PaykitPaymentProofService(sdk: sdk, store: store, logInfo: { _ in }, logWarning: { _ in })
            var failureOutcomes: [PrivatePaymentListSendOutcome] = []
            var releases = 0
            let releaseBeforeDispatch: () async -> Void = {
                releases += 1
                await proofService.cancelHardwarePaymentBeforeDispatch(request, paymentIdentity: identity, walletId: "trezor:original-ios-wallet")
            }
            var preparationCalls = 0
            var authorizationCalls = 0
            var isPaymentAllowed = true
            let preparePayment: (HwFundingSignedTx) async throws -> Void = { _ in
                preparationCalls += 1
                await store.seed([PendingPaykitPaymentProof(
                    identity: identity, requestId: request.id, paymentAppId: "bitkit",
                    paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
                    kind: .onchain, paymentStarted: true, paymentIdentifier: nil, proofData: nil, onchainWalletId: "trezor:original-ios-wallet"
                )])
            }
            let authorizePayment: () async throws -> Void = {
                authorizationCalls += 1
                if !isPaymentAllowed {
                    throw MockHwFunding.TestError()
                }
            }
            funding.broadcastError = broadcastError

            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager,
                    address: "bc1qtest",
                    sats: 42000,
                    satsPerVByte: 2,
                    beforeFirstBroadcast: preparePayment,
                    beforeBroadcastAttempt: authorizePayment,
                    afterFailure: { outcome in
                        failureOutcomes.append(outcome)
                        if outcome == .definitePreBroadcastFailure {
                            await releaseBeforeDispatch()
                        }
                    }
                )
            }

            funding.broadcastError = nil
            isPaymentAllowed = false
            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager,
                    address: "bc1qtest",
                    sats: 42000,
                    satsPerVByte: 2,
                    beforeFirstBroadcast: preparePayment,
                    beforeBroadcastAttempt: authorizePayment,
                    afterFailure: { outcome in
                        failureOutcomes.append(outcome)
                        if outcome == .definitePreBroadcastFailure {
                            await releaseBeforeDispatch()
                        }
                    }
                )
            }

            XCTAssertTrue(coordinator.hasPendingBroadcast)
            XCTAssertEqual(funding.broadcastCalls, 1)

            let durableProofs = await store.snapshot()
            XCTAssertEqual(durableProofs.count, 1)
            XCTAssertEqual(durableProofs.first?.paymentStarted, true, "Denied attempted retry must retain its durable original proof")
            XCTAssertEqual(failureOutcomes, [.uncertain, .uncertain])
            XCTAssertEqual(releases, 0, "Attempted retry incorrectly invoked pre-dispatch proof release")
            isPaymentAllowed = true
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeFirstBroadcast: preparePayment,
                beforeBroadcastAttempt: authorizePayment,
                afterFailure: { outcome in
                    failureOutcomes.append(outcome)
                    if outcome == .definitePreBroadcastFailure {
                        await releaseBeforeDispatch()
                    }
                }
            )

            XCTAssertEqual(preparationCalls, 1)
            XCTAssertEqual(authorizationCalls, 3)
            XCTAssertEqual(funding.signCalls, 1)
            XCTAssertEqual(funding.broadcastCalls, 2)
            XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
        }
    }

    func testConfirmedBroadcastCompletesProofBeforeReturningToCancelledCaller() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: MockHwConnecting())
        let completion = AsyncGate()
        var completionStarted = false
        var completedTransactionId: String?
        let payment = Task {
            try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                afterBroadcast: { result in
                    completionStarted = true
                    await completion.wait()
                    completedTransactionId = result.txId
                }
            )
        }
        await waitUntil { completionStarted }
        XCTAssertTrue(completionStarted)
        let wasPaused = await PrivatePaykitService.shared.isBackgroundWorkPaused
        addTeardownBlock { await PrivatePaykitService.shared.setBackgroundWorkPaused(wasPaused) }
        await PrivatePaykitService.shared.setBackgroundWorkPaused(true)
        manager.onAppBackgrounded()
        payment.cancel()
        coordinator.cancel()
        completion.open()

        let result = try await payment.value
        XCTAssertEqual(completedTransactionId, result.txId)
        XCTAssertEqual(result.txId, funding.broadcastTxId)
        XCTAssertEqual(funding.broadcastCalls, 1)
        coordinator.completeBroadcast()
    }

    func testCoordinatorDeniedFirstAttemptDropsPreparedPayment() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            walletId: "trezor:original-ios-wallet",
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: MockHwConnecting(),
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )

        let identity = "pubky" + String(repeating: "z", count: 52)
        let request = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(
            endpoints: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue]
        ), now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [])
        let proofService = PaykitPaymentProofService(sdk: sdk, store: store,
                                                     hardwareTransactionLookup: PaymentProofHardwareLookup(result: .failure(MockHwFunding
                                                             .TestError())), logInfo: { _ in }, logWarning: { _ in })
        let originalProof = PendingPaykitPaymentProof(
            identity: identity, requestId: request.id, paymentAppId: "bitkit",
            paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
            kind: .onchain, paymentStarted: true, paymentIdentifier: nil, proofData: nil,
            onchainAddress: "bc1qtest", onchainAmountSats: 42000, onchainWalletId: "trezor:original-ios-wallet"
        )
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeFirstBroadcast: { _ in
                    try await proofService.prepare(
                        request: request, paymentAppId: "bitkit",
                        paymentEndpointIdentifier: originalProof.paymentEndpointIdentifier,
                        kind: .onchain
                    )
                    try await proofService.markOnchainPaymentStarted(
                        request,
                        address: "bc1qtest",
                        hardwareWalletId: "trezor:original-ios-wallet",
                        paymentIdentity: identity
                    )
                },
                beforeBroadcastAttempt: { throw MockHwFunding.TestError() },
                afterFailure: { outcome in
                    if outcome == .definitePreBroadcastFailure {
                        await proofService.cancelHardwarePaymentBeforeDispatch(
                            request,
                            paymentIdentity: identity,
                            walletId: "trezor:original-ios-wallet"
                        )
                    }
                }
            )
        }

        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 0)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        let durableProofs = await store.snapshot()
        XCTAssertTrue(durableProofs.isEmpty, "Denied first attempt retained its started durable hardware proof despite zero dispatch")
    }

    func testCoordinatorCancelDropsSignedPaymentAfterFailedBroadcast() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            walletId: "trezor:wallet",
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: connecting,
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2
            )
        }

        XCTAssertTrue(coordinator.hasPendingBroadcast)

        coordinator.cancel()

        XCTAssertFalse(coordinator.hasPendingBroadcast)

        funding.broadcastError = nil
        _ = try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2
        )

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastCalls, 2)
    }

    func testCoordinatorDeniedFirstAttemptReleasesPreparedPaymentForRetry() async throws {
        for authorizationError in [MockHwFunding.TestError() as Error, CancellationError()] {
            let funding = MockHwFunding()
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(
                walletId: "trezor:wallet",
                signerFactory: { [self] _, address, satsPerVByte in
                    makeSigner(
                        funding: funding,
                        connecting: MockHwConnecting(),
                        feeRate: satsPerVByte,
                        address: address
                    )
                }
            )
            var preparationCalls = 0
            var failureOutcomes: [PrivatePaymentListSendOutcome] = []

            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager,
                    address: "bc1qtest",
                    sats: 42000,
                    satsPerVByte: 2,
                    beforeFirstBroadcast: { _ in preparationCalls += 1 },
                    beforeBroadcastAttempt: { throw authorizationError },
                    afterFailure: { failureOutcomes.append($0) }
                )
            }

            XCTAssertEqual(funding.signCalls, 1)
            XCTAssertEqual(funding.broadcastCalls, 0)
            XCTAssertFalse(coordinator.hasPendingBroadcast)
            XCTAssertEqual(failureOutcomes, [.definitePreBroadcastFailure])

            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeFirstBroadcast: { _ in preparationCalls += 1 }
            )

            XCTAssertEqual(preparationCalls, 2)
            XCTAssertEqual(funding.broadcastCalls, 1)
        }
    }

    func testPaymentDeadlineRejectionPreservesOnlyPriorBroadcastUncertainty() async throws {
        for hadPriorAttempt in [false, true] {
            for expiresInQueue in [false, true] {
                let funding = MockHwFunding()
                let manager = HwWalletManager()
                let coordinator = makeCoordinator(
                    walletId: "trezor:wallet",
                    signerFactory: { [self] _, address, satsPerVByte in
                        makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: satsPerVByte, address: address)
                    }
                )
                if hadPriorAttempt {
                    funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")
                    await assertThrowsAsync {
                        _ = try await coordinator.signAndBroadcast(manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2)
                    }
                    funding.broadcastError = nil
                }
                let priorNavigationWasUnresolved = coordinator.isBroadcastUnresolved
                let deadline = PaykitPreciseInstant(date: Date().addingTimeInterval(expiresInQueue ? 60 : -60))
                funding.broadcastNow = { deadline.date.addingTimeInterval(1) }
                var outcomes: [PrivatePaymentListSendOutcome] = []
                do {
                    _ = try await coordinator.signAndBroadcast(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                        paymentDeadline: deadline, afterFailure: { outcomes.append($0) }
                    )
                    XCTFail("Expired payment must not broadcast")
                } catch {
                    XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired)
                }
                XCTAssertEqual(funding.broadcastCalls, hadPriorAttempt ? 1 : 0)
                XCTAssertEqual(outcomes, [hadPriorAttempt ? .uncertain : .definitePreBroadcastFailure])
                XCTAssertEqual(coordinator.hasPendingBroadcast, hadPriorAttempt)
                XCTAssertEqual(coordinator.isBroadcastUnresolved, priorNavigationWasUnresolved)
            }
        }
    }

    func testHardwareSubmissionRechecksDeadlineAfterAwaitedPreparation() async throws {
        let deadline = PaykitPreciseInstant(date: Date().addingTimeInterval(1))
        let gate = AsyncGate()
        var callbackEnteredBeforeDeadline = false
        var nativeCalls = 0
        let task = Task { @MainActor in
            do {
                _ = try await OnChainHwService.broadcastAtBoundary(
                    paymentDeadline: deadline,
                    beforeDispatch: {
                        callbackEnteredBeforeDeadline = Date() < deadline.date
                        await gate.wait()
                    },
                    nativeBroadcast: { nativeCalls += 1; return "unexpected" }
                )
                XCTFail("Expiry during preparation must not enter native broadcast")
            } catch {
                XCTAssertEqual((error as? PreparedOnchainSendNotSubmitted)?.underlying as? PaykitPaymentRequestError, .requestExpired)
            }
        }
        await waitUntil { callbackEnteredBeforeDeadline }
        XCTAssertTrue(callbackEnteredBeforeDeadline, "The callback must start while authorization remains valid")
        try await Task.sleep(nanoseconds: UInt64(max(0, deadline.date.timeIntervalSinceNow + 0.02) * 1_000_000_000))
        gate.open()
        await task.value
        XCTAssertEqual(nativeCalls, 0)
    }

    func testHardwareSubmissionRechecksCancellationAfterAwaitedPreparation() async {
        var prepared = false
        var nativeCalls = 0
        let task = Task { @MainActor in
            do {
                _ = try await OnChainHwService.broadcastAtBoundary(
                    paymentDeadline: nil,
                    beforeDispatch: { prepared = true; withUnsafeCurrentTask { $0?.cancel() } },
                    nativeBroadcast: { nativeCalls += 1; return "unexpected" }
                )
                XCTFail("Cancellation during preparation must not enter native broadcast")
            } catch {
                XCTAssertTrue((error as? PreparedOnchainSendNotSubmitted)?.underlying is CancellationError)
            }
        }
        await task.value
        XCTAssertTrue(prepared)
        XCTAssertEqual(nativeCalls, 0)
    }

    func testRefusedShopRetryExpiryDuringDispatchPreparationKeepsHintAndOriginalBytes() async {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        let receipt = funding.signedTx
        var stored = RetainedHardwareOnchainPayment(signedTx: receipt, hasAttemptedBroadcast: true, isRefusedForNavigation: true)
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let deadline = PaykitPreciseInstant(date: Date().addingTimeInterval(60))
        let gate = AsyncGate()
        var preparing = false
        let task = Task { @MainActor in
            do {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    paymentDeadline: deadline, paymentRequestId: requestId, loadSignedPayment: { stored },
                    markSignedPaymentRefused: { _, refused in
                        stored.isRefusedForNavigation = refused
                        if !refused {
                            preparing = true; await gate.wait()
                        }
                    }
                )
                XCTFail("An expiry after awaited preparation must not dispatch")
            } catch { XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired) }
        }
        await waitUntil { preparing }
        XCTAssertTrue(preparing)
        funding.broadcastNow = { deadline.date.addingTimeInterval(1) }
        gate.open()
        await task.value
        XCTAssertEqual(funding.broadcastCalls, 0)
        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(stored.signedTx, receipt)
        XCTAssertTrue(stored.isRefusedForNavigation)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertTrue(coordinator.canLeave)
    }

    func testHardwareSubmissionRejectsExpiredDeadlineBeforeCallingElectrum() async throws {
        do {
            _ = try await OnChainHwService.shared.broadcastRawTx(
                serializedTx: "invalid", electrumUrl: "invalid",
                paymentDeadline: PaykitPreciseInstant(date: Date().addingTimeInterval(-1))
            )
            XCTFail("Expired payment must not reach Electrum")
        } catch {
            let underlying = (error as? Bitkit.AppError)?.underlyingError ?? error
            let failure = (underlying as? PreparedOnchainSendNotSubmitted)?.underlying ?? underlying
            XCTAssertEqual(failure as? PaykitPaymentRequestError, .requestExpired)
        }
    }

    func testCoordinatorBroadcastFailureRemainsUncertainAfterPendingPaymentIsCleared() async {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            walletId: "trezor:wallet",
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: MockHwConnecting(),
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        var failureOutcomes: [PrivatePaymentListSendOutcome] = []
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "Broadcast failed: min relay fee not met")

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                afterFailure: { failureOutcomes.append($0) }
            )
        }

        XCTAssertFalse(coordinator.hasPendingBroadcast)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(failureOutcomes, [.uncertain])

        funding.broadcastError = nil
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeFirstBroadcast: { _ in throw PaykitPaymentRequestError.operationInProgress },
                afterFailure: { failureOutcomes.append($0) }
            )
        }

        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(failureOutcomes, [.uncertain])
    }

    func testCoordinatorRetriesPreparationFailureBeforeBroadcast() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            walletId: "trezor:wallet",
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: MockHwConnecting(),
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        var beforeFirstBroadcastCalls = 0

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeFirstBroadcast: { _ in
                    beforeFirstBroadcastCalls += 1
                    throw MockHwFunding.TestError()
                }
            )
        }

        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertEqual(funding.broadcastCalls, 0)

        _ = try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            beforeFirstBroadcast: { _ in beforeFirstBroadcastCalls += 1 }
        )

        XCTAssertEqual(beforeFirstBroadcastCalls, 2)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 1)
    }

    private func assertCoordinatorRetryReusesSignedPayment(error: Error) async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(
            walletId: "trezor:wallet",
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: connecting,
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
        var preparationCalls = 0
        var authorizationCalls = 0
        var completedTransactionIds: [String] = []
        funding.broadcastError = error

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeFirstBroadcast: { _ in preparationCalls += 1 },
                beforeBroadcastAttempt: { authorizationCalls += 1 },
                afterBroadcast: { completedTransactionIds.append($0.txId) }
            )
        }

        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertFalse(coordinator.isBroadcastUnresolved)
        XCTAssertFalse(coordinator.isSigning)

        funding.broadcastError = nil
        _ = try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            beforeFirstBroadcast: { _ in preparationCalls += 1 },
            beforeBroadcastAttempt: { authorizationCalls += 1 },
            afterBroadcast: { completedTransactionIds.append($0.txId) }
        )

        XCTAssertEqual(funding.composeCalls.count, 1)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
        XCTAssertEqual(preparationCalls, 1)
        XCTAssertEqual(authorizationCalls, 2)
        XCTAssertEqual(completedTransactionIds, [funding.broadcastTxId])
    }

    // MARK: - Leaving the sign screen

    func testCoordinatorCanBeLeftWhileTheDeviceConnects() async throws {
        for walletId in ["jade:wallet", "trezor:wallet"] {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let connect = AsyncGate()
            connecting.connectGate = connect
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(walletId: walletId, funding: funding, connecting: connecting)

            let payment = Task { try await self.signAndBroadcast(coordinator, manager: manager) }
            await waitUntil { coordinator.isConnectingDevice }

            XCTAssertTrue(coordinator.isSigning, walletId)
            XCTAssertTrue(coordinator.isConnectingDevice, walletId)
            XCTAssertTrue(coordinator.canLeave, walletId)

            connect.open()
            _ = try await payment.value

            XCTAssertFalse(coordinator.isConnectingDevice, walletId)
            XCTAssertFalse(coordinator.isSigning, walletId)
            XCTAssertEqual(funding.broadcastCalls, 1, walletId)
        }
    }

    func testCoordinatorCannotBeLeftWhileTheDeviceSigns() async throws {
        let funding = MockHwFunding()
        let sign = AsyncGate()
        funding.signGate = sign
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())

        let payment = Task { try await self.signAndBroadcast(coordinator, manager: manager) }
        await waitUntil { funding.signCalls == 1 }

        XCTAssertTrue(coordinator.isSigning)
        XCTAssertFalse(coordinator.isConnectingDevice)
        XCTAssertFalse(coordinator.canLeave)

        sign.open()
        _ = try await payment.value
    }

    func testShopBroadcastFailurePreservesSignedPaymentAcrossCancel() async throws {
        for details in [
            "offline", "unrecognized backend error",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -25: disconnected\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -26: unknown refusal\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -25x: bad-txns-inputs-missingorspent\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -25: bad-txns-inputs-missingorspent-ish\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -26: insufficient fee, rejecting replacement-ish\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -26: insufficient fee, rejecting replacement disconnected\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -25: bad-txns-inputs-missingorspent",
            "Broadcast failed: Electrum server error: [\"sendrawtransaction RPC error -25: bad-txns-inputs-missingorspent\"]",
            "broadcast failed: disconnected", "broadcast failed: unknown refusal",
            "Broadcast failed: Electrum server error: {\"code\":-26,\"message\":\"unknown refusal\"}",
            "Broadcast failed: Electrum server error: {\"code\":-26,\"message\":\"disconnected\",\"data\":\"non-final\"}",
            "Broadcast failed: Electrum server error: {\"code\":1,\"message\":\"the transaction was rejected by network rules.\\n\\ndisconnected\\n[non-final]\"}",
            "Broadcast failed: Electrum server error: {\"code\":2,\"message\":\"sendrawtransaction RPC error: {\\\"message\\\":\\\"unknown refusal\\\",\\\"data\\\":\\\"non-final\\\"}\"}",
        ] {
            let funding = MockHwFunding()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
            let manager = HwWalletManager()
            let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
            funding.broadcastError = BroadcastError.ElectrumError(errorDetails: details)
            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
                )
            }
            XCTAssertTrue(coordinator.isBroadcastUnresolved)
            XCTAssertFalse(coordinator.canLeave)
            coordinator.cancel()
            XCTAssertTrue(coordinator.hasPendingBroadcast)
            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    paymentRequestId: .init(paymentRequestId: "other-request", counterparty: "original-merchant")
                )
            }
            XCTAssertEqual(funding.broadcastCalls, 1)
            funding.broadcastError = nil
            _ = try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
            )
            XCTAssertEqual(funding.signCalls, 1)
            XCTAssertEqual(funding.broadcastCalls, 2)
        }
    }

    func testRetainedConfirmationRepeatSwipeIgnoresPresetAndKeepsOriginalBytes() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        let signed = funding.signedTx
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "broadcast failed: min relay fee not met")
        var authorized = 0
        for preset: UInt32 in [17, 99] {
            let rate = try XCTUnwrap(SendConfirmationView.confirmationFeeRate(retained: signed, selected: preset))
            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: UInt64(rate), paymentRequestId: requestId,
                    loadSignedPayment: { RetainedHardwareOnchainPayment(signedTx: signed, hasAttemptedBroadcast: true, isRefusedForNavigation: true)
                    },
                    beforeFirstBroadcast: { _ in XCTFail("Must not prepare a new payment") },
                    beforeBroadcastAttempt: { authorized += 1 }
                )
            } _: { error in
                XCTAssertTrue(error is BroadcastError, "Expected the original native refusal, not another request: \(error)")
            }
            XCTAssertTrue(coordinator.canLeave)
        }
        XCTAssertEqual(authorized, 2)
        XCTAssertEqual(funding.broadcastCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions, [signed.serializedTx, signed.serializedTx])
        XCTAssertTrue(funding.composeCalls.isEmpty)
        XCTAssertEqual(funding.signCalls, 0)
    }

    func testShopDefiniteRefusalAllowsLeavingAndRetainsOriginalSignedPayment() async throws {
        let messages = [
            "min relay fee not met, 110 < 123",
            "mempool min fee not met, 110 < 1000",
            "bad-txns-inputs-missingorspent", "txn-mempool-conflict", "non-final",
            "the transaction was rejected by network rules.\n\nmin relay fee not met, 100 < 110\n[0200000001...]",
            "sendrawtransaction RPC error: {\"code\":-26,\"message\":\"bad-txns-inputs-missingorspent\"}",
        ]
        let serverErrors = try messages.map { message in
            let json = try JSONSerialization.data(withJSONObject: ["code": 1, "message": message])
            return BroadcastError.ElectrumError(errorDetails: "Broadcast failed: Electrum server error: " + String(decoding: json, as: UTF8.self))
        }
        let stringErrors = [
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -25: bad-txns-inputs-missingorspent\"",
            "Broadcast failed: Electrum server error: \"sendrawtransaction RPC error -26: insufficient fee, rejecting replacement b3f63e62aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; new feerate 0.00001000 BTC/kvB <= old feerate 0.00001018 BTC/kvB\"",
        ].map { BroadcastError.ElectrumError(errorDetails: $0) }
        for error in [
            BroadcastError.InvalidHex(errorDetails: "invalid hex"),
            BroadcastError.InvalidTransaction(errorDetails: "invalid transaction"),
            BroadcastError.ElectrumError(errorDetails: "broadcast failed: min relay fee not met"),
        ] + serverErrors + stringErrors {
            let funding = MockHwFunding()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
            let manager = HwWalletManager()
            let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
            funding.broadcastError = error
            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
                )
            }
            XCTAssertFalse(coordinator.isBroadcastUnresolved)
            XCTAssertTrue(coordinator.canLeave)
            coordinator.cancel()
            XCTAssertTrue(coordinator.hasPendingBroadcast)
            await assertThrowsAsync {
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    paymentRequestId: .init(paymentRequestId: "other-request", counterparty: "original-merchant")
                )
            }
            XCTAssertEqual(funding.broadcastCalls, 1)
            funding.broadcastError = nil
            _ = try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
            )
            XCTAssertEqual(funding.signCalls, 1)
            XCTAssertEqual(funding.broadcastCalls, 2)
        }
    }

    func testRefusedShopRestoreAndFeeRefreshRemainDismissibleBeforeRetryDispatch() async throws {
        for relaunch in [false, true] {
            for (denial, expiresInQueue) in [
                (PaykitPaymentRequestError.requestExpired, false),
                (.requestUnavailable, false),
                (.operationInProgress, false),
                (.requestExpired, true),
            ] {
                let funding = MockHwFunding()
                let manager = HwWalletManager()
                let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
                var stored: RetainedHardwareOnchainPayment?
                let retain: (HwFundingSignedTx) async throws -> Void = {
                    stored = RetainedHardwareOnchainPayment(
                        signedTx: $0, hasAttemptedBroadcast: true, isRefusedForNavigation: stored?.isRefusedForNavigation == true
                    )
                }
                let markRefused: (HwFundingSignedTx, Bool) async throws -> Void = { signed, refused in
                    XCTAssertEqual(stored?.signedTx, signed)
                    stored?.isRefusedForNavigation = refused
                }
                let original = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
                funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "broadcast failed: min relay fee not met")
                await assertThrowsAsync {
                    _ = try await original.signAndBroadcast(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                        paymentRequestId: requestId, retainSignedPayment: retain, markSignedPaymentRefused: markRefused
                    )
                }
                XCTAssertTrue(original.canLeave)
                let retry = relaunch ? makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting()) : original
                if !relaunch {
                    _ = try await retry.preparePreview(manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 3)
                }
                funding.broadcastError = nil
                let deadline = PaykitPreciseInstant(date: Date().addingTimeInterval(60))
                if expiresInQueue {
                    funding.broadcastNow = { deadline.date.addingTimeInterval(1) }
                }
                await assertThrowsAsync {
                    _ = try await retry.signAndBroadcast(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: relaunch ? 2 : 3,
                        paymentDeadline: expiresInQueue ? deadline : nil, paymentRequestId: requestId, loadSignedPayment: { stored },
                        beforeBroadcastAttempt: {
                            if !expiresInQueue, denial != .operationInProgress {
                                throw denial
                            }
                        },
                        retainSignedPayment: {
                            signed in if expiresInQueue {
                                try await retain(signed)
                            } else {
                                throw denial
                            }
                        },
                        markSignedPaymentRefused: markRefused
                    )
                }
                XCTAssertEqual(funding.signCalls, 1)
                XCTAssertEqual(funding.broadcastCalls, 1)
                XCTAssertTrue(retry.hasPendingBroadcast)
                XCTAssertTrue(retry.canLeave, "Restore must preserve refusal navigation before another dispatch")
                retry.cancel()
                XCTAssertTrue(retry.hasPendingBroadcast)
                XCTAssertEqual(stored?.isRefusedForNavigation, true)
                funding.broadcastNow = Date.init
                funding.broadcastError = HwTransferError.broadcastUncertain
                await assertThrowsAsync {
                    _ = try await retry.signAndBroadcast(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: relaunch ? 2 : 3,
                        paymentRequestId: requestId, loadSignedPayment: { stored },
                        retainSignedPayment: retain, markSignedPaymentRefused: markRefused
                    )
                }
                XCTAssertEqual(stored?.isRefusedForNavigation, false, "A real new dispatch consumes the navigation hint")
                XCTAssertFalse(retry.canLeave)
                XCTAssertEqual(funding.signCalls, 1)
                XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
            }
        }
    }

    func testExpiredShopRetryPreservesPriorNavigationStateAndSignedPayment() async throws {
        for details in ["broadcast failed: min relay fee not met", "offline"] {
            for expiresInQueue in [false, true] {
                let funding = MockHwFunding()
                let manager = HwWalletManager()
                let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
                let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
                funding.broadcastError = BroadcastError.ElectrumError(errorDetails: details)
                await assertThrowsAsync {
                    _ = try await coordinator.signAndBroadcast(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
                    )
                }
                let couldLeave = coordinator.canLeave
                funding.broadcastError = nil
                let deadline = PaykitPreciseInstant(date: Date().addingTimeInterval(60))
                funding.broadcastNow = { deadline.date.addingTimeInterval(1) }
                var outcomes: [PrivatePaymentListSendOutcome] = []
                await assertThrowsAsync {
                    _ = try await coordinator.signAndBroadcast(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                        paymentDeadline: deadline, paymentRequestId: requestId,
                        beforeBroadcastAttempt: {
                            if !expiresInQueue {
                                throw PaykitPaymentRequestError.requestExpired
                            }
                        },
                        afterFailure: { outcomes.append($0) }
                    )
                }
                XCTAssertEqual(coordinator.canLeave, couldLeave, "A never-submitted retry must not change prior navigation uncertainty")
                XCTAssertTrue(coordinator.hasPendingBroadcast)
                XCTAssertEqual(funding.broadcastCalls, 1)
                XCTAssertEqual(outcomes, [.uncertain], "The earlier submitted bytes remain guarded")
                coordinator.cancel()
                funding.broadcastNow = Date.init
                _ = try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
                )
                XCTAssertEqual(funding.signCalls, 1)
                XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
            }
        }
    }

    func testRestoredShopReceiptRequiresAuthorizationAndNeverSignsAgain() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        let receipt = funding.signedTx
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId,
                loadSignedPayment: { RetainedHardwareOnchainPayment(signedTx: receipt, hasAttemptedBroadcast: true) },
                beforeFirstBroadcast: { _ in XCTFail("Restored proof must not prepare another payment") },
                beforeBroadcastAttempt: { throw MockHwFunding.TestError() }
            )
        }
        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(funding.broadcastCalls, 0)
        XCTAssertTrue(coordinator.isBroadcastUnresolved)
        _ = try await coordinator.signAndBroadcast(
            manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId,
            beforeFirstBroadcast: { _ in XCTFail("Original preparation retained") }
        )
        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(funding.broadcastTransactions, [receipt.serializedTx])
    }

    func testRestoredUnattemptedShopReceiptDenialIsDefinitelyBeforeDispatch() async {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        var outcomes: [PrivatePaymentListSendOutcome] = []
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId,
                loadSignedPayment: { RetainedHardwareOnchainPayment(signedTx: funding.signedTx, hasAttemptedBroadcast: false) },
                beforeFirstBroadcast: { _ in XCTFail("Restored proof must not prepare another payment") },
                beforeBroadcastAttempt: { throw MockHwFunding.TestError() },
                afterFailure: { outcomes.append($0) }
            )
        }
        XCTAssertEqual(outcomes, [.definitePreBroadcastFailure])
        XCTAssertFalse(coordinator.isBroadcastUnresolved)
        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(funding.broadcastCalls, 0)
    }

    func testObservedShopPaymentUnlocksOnlyOriginalSignedCandidate() async throws {
        let funding = MockHwFunding()
        funding.signedTx = HwFundingSignedTx(
            serializedTx: "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300",
            miningFeeSats: 141,
            feeRate: 2,
            totalSpent: 42141
        )
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        let identity = "pubky" + String(repeating: "z", count: 52)
        let txid = try SignedTransactionId.fromHex(funding.signedTx.serializedTx)
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "response lost")
        let broadcast = AsyncGate()
        funding.broadcastGate = broadcast
        let original = PaykitOnchainPaymentResolution(identity: identity, requestId: requestId, transactionId: txid, walletId: "jade:wallet")
        let payment = Task { try await coordinator.signAndBroadcast(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId
        ) }
        await waitUntil { funding.broadcastCalls == 1 }
        XCTAssertNil(coordinator.resolveObservedShopPayment(original, paymentIdentity: identity, currentIdentity: identity))
        XCTAssertFalse(coordinator.canLeave)
        broadcast.open()
        await assertThrowsAsync { _ = try await payment.value }
        for unrelated in [
            PaykitOnchainPaymentResolution(identity: identity, requestId: requestId, transactionId: "other", walletId: "jade:wallet"),
            PaykitOnchainPaymentResolution(identity: identity, requestId: requestId, transactionId: txid, walletId: "other"),
            PaykitOnchainPaymentResolution(
                identity: identity,
                requestId: .init(paymentRequestId: "other", counterparty: "original-merchant"),
                transactionId: txid,
                walletId: "jade:wallet"
            ),
            PaykitOnchainPaymentResolution(
                identity: "pubky" + String(repeating: "x", count: 52),
                requestId: requestId,
                transactionId: txid,
                walletId: "jade:wallet"
            ),
        ] {
            XCTAssertNil(coordinator.resolveObservedShopPayment(unrelated, paymentIdentity: identity, currentIdentity: identity))
            XCTAssertFalse(coordinator.canLeave)
        }
        XCTAssertNil(coordinator.resolveObservedShopPayment(
            original,
            paymentIdentity: identity,
            currentIdentity: "pubky" + String(repeating: "x", count: 52)
        ))
        XCTAssertEqual(
            coordinator.resolveObservedShopPayment(original, paymentIdentity: identity, currentIdentity: identity),
            .success(paymentId: txid, walletId: "jade:wallet")
        )
        XCTAssertTrue(coordinator.canLeave)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        XCTAssertNil(coordinator.resolveObservedShopPayment(original, paymentIdentity: identity, currentIdentity: identity))
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 1)
    }

    func testHardwareCandidateSaveFailurePreventsNativeDispatch() async {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                paymentRequestId: .init(paymentRequestId: "original", counterparty: "merchant"),
                retainSignedPayment: { signed in
                    XCTAssertEqual(signed, funding.signedTx)
                    XCTAssertEqual(funding.broadcastCalls, 0)
                    throw MockHwFunding.TestError()
                }
            )
        }
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 0)
    }

    func testHardwareCandidateSaveFailureRetriesFreshPreparation() async throws {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original", counterparty: "merchant")
        var preparations = 0
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                paymentRequestId: requestId,
                beforeFirstBroadcast: { _ in preparations += 1 },
                retainSignedPayment: { _ in throw MockHwFunding.TestError() }
            )
        }
        _ = try await coordinator.signAndBroadcast(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
            paymentRequestId: requestId,
            beforeFirstBroadcast: { _ in preparations += 1 }
        )
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(funding.broadcastCalls, 1)
    }

    func testCoordinatorCannotBeLeftWhileABroadcastIsUnresolved() async throws {
        let funding = MockHwFunding()
        let broadcast = AsyncGate()
        funding.broadcastGate = broadcast
        let connecting = MockHwConnecting()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting)

        let payment = Task { try await self.signAndBroadcast(coordinator, manager: manager) }
        await waitUntil { funding.broadcastCalls == 1 }

        XCTAssertTrue(coordinator.isBroadcastUnresolved)
        XCTAssertFalse(coordinator.canLeave)

        coordinator.cancel()

        XCTAssertTrue(coordinator.isSigning, "a broadcast that may have gone out is not cancelled")
        XCTAssertTrue(connecting.staleDisconnects.isEmpty)

        broadcast.open()
        let result = try await payment.value

        XCTAssertEqual(result.txId, funding.broadcastTxId)
        XCTAssertFalse(coordinator.canLeave, "the outcome stays unresolved until the sheet records it")
        coordinator.completeBroadcast()
        XCTAssertTrue(coordinator.canLeave)
    }

    func testCancelWhileConnectingStopsBeforeSigningAndReleasesTheDevice() async throws {
        for walletId in ["jade:wallet", "trezor:wallet"] {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let abandonedConnect = AsyncGate()
            connecting.connectGate = abandonedConnect
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(walletId: walletId, funding: funding, connecting: connecting)

            let payment = Task { try await self.signAndBroadcast(coordinator, manager: manager) }
            await waitUntil { coordinator.isConnectingDevice }
            coordinator.cancel()

            XCTAssertEqual(connecting.staleDisconnects, [walletId], "leaving releases the device")
            XCTAssertFalse(coordinator.isSigning, walletId)
            XCTAssertFalse(coordinator.isConnectingDevice, walletId)
            XCTAssertTrue(coordinator.canLeave, walletId)
            await assertThrowsAsync {
                _ = try await payment.value
            } _: { error in
                XCTAssertTrue(error is CancellationError, "\(error)")
            }

            connecting.connectGate = nil
            abandonedConnect.open()
            await Task.yield()

            XCTAssertTrue(funding.composeCalls.isEmpty, walletId)
            XCTAssertEqual(funding.signCalls, 0, walletId)
            XCTAssertEqual(funding.broadcastCalls, 0, walletId)

            let result = try await signAndBroadcast(coordinator, manager: manager)

            XCTAssertEqual(result.txId, funding.broadcastTxId, walletId)
            XCTAssertEqual(funding.composeCalls.count, 1, walletId)
            XCTAssertEqual(funding.broadcastCalls, 1, walletId)
            XCTAssertEqual(connecting.staleDisconnects, [walletId], "the new attempt keeps its session")
        }
    }

    func testACancelledAttemptDoesNotResetANewerAttempt() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let preparations = JadeCallLog()
        let firstPreparation = AsyncGate()
        let secondPreparation = AsyncGate()

        let first = Task {
            try await self.signAndBroadcast(coordinator, manager: manager) { _ in
                preparations.record("first")
                await firstPreparation.wait()
            }
        }
        await waitUntil { preparations.contains("first") }
        coordinator.cancel()

        let second = Task {
            try await self.signAndBroadcast(coordinator, manager: manager) { _ in
                preparations.record("second")
                await secondPreparation.wait()
            }
        }
        await waitUntil { preparations.contains("second") }
        firstPreparation.open()
        await assertThrowsAsync {
            _ = try await first.value
        } _: { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertTrue(coordinator.isSigning, "the cancelled attempt must not end the newer one")
        XCTAssertFalse(coordinator.canLeave)
        XCTAssertEqual(funding.broadcastCalls, 0, "a cancelled attempt never broadcasts")

        secondPreparation.open()
        let result = try await second.value

        XCTAssertEqual(result.txId, funding.broadcastTxId)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertFalse(coordinator.isSigning)
    }

    func testCancelledAuthorizationKeepsOwnershipUntilProofCleanupFinishes() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let authorization = AsyncGate()
        let cleanup = AsyncGate()
        var authorizationStarted = false
        var cleanupStarted = false
        var proofStarted = false
        var outcomes: [PrivatePaymentListSendOutcome] = []
        let first = Task {
            try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                beforeFirstBroadcast: { _ in proofStarted = true },
                beforeBroadcastAttempt: {
                    authorizationStarted = true
                    await authorization.wait()
                },
                afterFailure: { outcome in
                    outcomes.append(outcome)
                    cleanupStarted = true
                    await cleanup.wait()
                    proofStarted = false
                }
            )
        }
        await waitUntil { authorizationStarted }
        XCTAssertTrue(proofStarted)
        coordinator.cancel()
        authorization.open()
        await waitUntil { cleanupStarted || !coordinator.isSigning }
        XCTAssertTrue(cleanupStarted, "Cancellation must release the definitely unsent original proof")
        XCTAssertEqual(outcomes, [.definitePreBroadcastFailure])
        XCTAssertEqual(funding.broadcastCalls, 0)
        var secondPrepared = false
        let second = Task {
            try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                beforeFirstBroadcast: { _ in secondPrepared = true }
            )
        }
        await Task.yield()
        XCTAssertFalse(secondPrepared, "New proof preparation must wait for the original cleanup")
        cleanup.open()
        await assertThrowsAsync { _ = try await first.value } _: { XCTAssertTrue($0 is CancellationError) }
        await assertThrowsAsync { _ = try await second.value } _: { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(proofStarted)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        _ = try await signAndBroadcast(coordinator, manager: manager)
        XCTAssertEqual(funding.broadcastCalls, 1)
    }

    func testCancellationKeepsReceiptOwnershipUntilRetentionCleanupCompletes() async throws {
        for cleanupSucceeds in [true, false] {
            let funding = MockHwFunding()
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
            let retaining = AsyncGate()
            let clearing = AsyncGate()
            var receipt: HwFundingSignedTx?
            var retainingStarted = false
            var clearingStarted = false
            var concurrentStarted = false
            var loads = 0
            var authCalls = 0
            let send = {
                try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    loadSignedPayment: {
                        loads += 1
                        return receipt.map { RetainedHardwareOnchainPayment(signedTx: $0, hasAttemptedBroadcast: false) }
                    },
                    beforeBroadcastAttempt: { authCalls += 1 },
                    retainSignedPayment: { signed in
                        receipt = signed
                        retainingStarted = true
                        await retaining.wait()
                    },
                    clearSignedPaymentBeforeDispatch: { _ in
                        clearingStarted = true
                        await clearing.wait()
                        if cleanupSucceeds {
                            receipt = nil
                        }
                        return cleanupSucceeds
                    }
                )
            }
            let first = Task { try await send() }
            await waitUntil { retainingStarted }
            XCTAssertTrue(retainingStarted)
            coordinator.cancel()
            let concurrent = Task {
                concurrentStarted = true
                return try await send()
            }
            await waitUntil { concurrentStarted }
            retaining.open()
            await waitUntil { clearingStarted }
            XCTAssertTrue(clearingStarted)
            XCTAssertEqual(loads, 1, "no newer attempt may reuse the receipt being cleared")
            XCTAssertEqual(authCalls, 1)
            XCTAssertEqual(funding.broadcastCalls, 0)
            clearing.open()
            for payment in [first, concurrent] {
                await assertThrowsAsync {
                    _ = try await payment.value
                } _: { error in
                    XCTAssertTrue(error is CancellationError, "\(error)")
                }
            }
            XCTAssertEqual(coordinator.isBroadcastUnresolved, !cleanupSucceeds)
            XCTAssertEqual(coordinator.hasPendingBroadcast, !cleanupSucceeds)
            XCTAssertEqual(receipt == nil, cleanupSucceeds)
            XCTAssertEqual(funding.broadcastCalls, 0)
            if cleanupSucceeds {
                _ = try await send()
                XCTAssertEqual(funding.broadcastCalls, 1)
                XCTAssertEqual(loads, 2)
                XCTAssertNotNil(receipt, "the new submitted attempt retains its own receipt")
            }
        }
    }

    func testRecreatedCoordinatorCannotAdoptReceiptUntilCancelledOwnerFinishesCleanup() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let firstCoordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let reopenedCoordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let proofService = PaykitPaymentProofService(
            sdk: PaymentProofSdkMock(identity: "pubky" + String(repeating: "z", count: 52), records: []),
            store: PaymentProofMemoryStore(), logInfo: { _ in }, logWarning: { _ in }
        )
        let retaining = AsyncGate()
        let clearing = AsyncGate()
        var receipt: HwFundingSignedTx?
        var retainingStarted = false
        var clearingStarted = false
        var loads = 0
        let first = Task {
            try await proofService.withHardwarePaymentOwnership(walletId: "jade:wallet") {
                try await firstCoordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    loadSignedPayment: { loads += 1; return nil },
                    retainSignedPayment: { signed in
                        receipt = signed
                        retainingStarted = true
                        await retaining.wait()
                    },
                    clearSignedPaymentBeforeDispatch: { _ in
                        clearingStarted = true
                        await clearing.wait()
                        receipt = nil
                        return true
                    }
                )
            }
        }
        await waitUntil { retainingStarted }
        XCTAssertTrue(retainingStarted)
        firstCoordinator.cancel()
        let sendFromReopenedSheet = {
            try await proofService.withHardwarePaymentOwnership(walletId: "jade:wallet") {
                try await reopenedCoordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    loadSignedPayment: {
                        loads += 1
                        return receipt.map { RetainedHardwareOnchainPayment(signedTx: $0, hasAttemptedBroadcast: false) }
                    },
                    retainSignedPayment: { receipt = $0 }
                )
            }
        }
        await assertThrowsAsync { _ = try await sendFromReopenedSheet() } _: { error in
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }
        retaining.open()
        await waitUntil { clearingStarted }
        XCTAssertTrue(clearingStarted)
        await assertThrowsAsync { _ = try await sendFromReopenedSheet() } _: { error in
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }
        XCTAssertEqual(loads, 1, "the recreated sheet must not even load the old owner's receipt")
        XCTAssertEqual(funding.broadcastCalls, 0)
        let otherWallet = try await proofService.withHardwarePaymentOwnership(walletId: "jade:other-wallet") { true }
        XCTAssertTrue(otherWallet, "ownership is scoped to the original hardware wallet")
        clearing.open()
        await assertThrowsAsync { _ = try await first.value } _: { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(receipt)
        _ = try await sendFromReopenedSheet()
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(loads, 2)
        XCTAssertNotNil(receipt, "cleanup from the old owner cannot remove the new payment")
    }

    func testCancelWithNothingInFlightKeepsTheSession() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting)

        coordinator.cancel()

        XCTAssertTrue(connecting.staleDisconnects.isEmpty)

        _ = try await signAndBroadcast(coordinator, manager: manager)
        coordinator.completeBroadcast()
        coordinator.cancel()

        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "a finished payment keeps its session")
    }

    func testCoordinatorCanBeLeftWhileTheDeviceReconnectsBeforeASignRetry() async {
        let walletId = "jade:wallet"
        let funding = MockHwFunding()
        funding.signErrors = [Bitkit.AppError(error: JadeError.DeviceDisconnected)]
        let sign = AsyncGate()
        funding.signGate = sign
        let connecting = MockHwConnecting()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: walletId, funding: funding, connecting: connecting)

        let payment = Task { try await self.signAndBroadcast(coordinator, manager: manager) }
        await waitUntil { funding.signCalls == 1 }
        let abandonedReconnect = AsyncGate()
        connecting.connectGate = abandonedReconnect
        sign.open()
        await waitUntil { coordinator.isConnectingDevice }

        XCTAssertTrue(coordinator.isSigning)
        XCTAssertTrue(coordinator.isConnectingDevice)
        XCTAssertTrue(coordinator.canLeave, "nothing is on the device to sign while it reconnects")

        coordinator.cancel()

        await assertThrowsAsync {
            _ = try await payment.value
        } _: { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(connecting.staleDisconnects, [walletId, walletId], "the failed sign and leaving each release the device")

        abandonedReconnect.open()
        await Task.yield()

        XCTAssertEqual(funding.signCalls, 1, "the abandoned reconnect never signs again")
        XCTAssertEqual(funding.broadcastCalls, 0)
    }

    func testConnectingIsReportedAroundEveryReconnect() async throws {
        let funding = MockHwFunding()
        funding.signErrors = [Bitkit.AppError(error: JadeError.DeviceDisconnected)]
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting)
        var reports: [Bool] = []

        _ = try await signer.prepareSignedPayment(
            walletId: "jade:wallet",
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            onConnectingDevice: { reports.append($0) }
        )

        XCTAssertEqual(connecting.ensureCalls, 2)
        XCTAssertEqual(reports, [true, false, true, false], "the reconnect before the sign retry is reported too")

        reports = []
        connecting.connectError = MockHwFunding.TestError()
        await assertThrowsAsync {
            _ = try await signer.prepareSignedPayment(
                walletId: "jade:wallet",
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                onConnectingDevice: { reports.append($0) }
            )
        }

        XCTAssertEqual(reports, [true, false], "a failed reconnect still ends the report")
    }

    private func makeCoordinator(
        walletId: String,
        funding: MockHwFunding,
        connecting: MockHwConnecting
    ) -> HwSendCoordinator {
        makeCoordinator(
            walletId: walletId,
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: connecting,
                    feeRate: satsPerVByte,
                    address: address
                )
            }
        )
    }

    private func signAndBroadcast(
        _ coordinator: HwSendCoordinator,
        manager: HwWalletManager,
        beforeFirstBroadcast: @escaping (HwFundingSignedTx) async throws -> Void = { _ in }
    ) async throws -> HwFundingBroadcastResult {
        try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            beforeFirstBroadcast: beforeFirstBroadcast
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Availability

    func testAvailabilityUsesRealMaxSpendable() async throws {
        let funding = MockHwFunding()
        funding.account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
        funding.maxSpendable = 990_000
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: 2)

        let availability = try await signer.availability(walletId: "trezor:wallet")

        XCTAssertEqual(availability.balanceSats, 1_000_000)
        XCTAssertEqual(availability.available, 990_000, "available comes from the real sendMax estimate")
        XCTAssertEqual(funding.maxSpendableCalls.first?.satsPerVByte, 2)
        XCTAssertEqual(funding.maxSpendableCalls.first?.address, "bc1qtest")
    }

    func testAvailabilityClampsSpendableToBalance() async throws {
        let funding = MockHwFunding()
        funding.account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 800_000)
        funding.maxSpendable = 990_000
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: 2)

        let availability = try await signer.availability(walletId: "trezor:wallet")

        XCTAssertEqual(availability.available, 800_000, "available is clamped to the device balance")
    }

    func testAvailabilityFallsBackToReserveWhenEstimateFails() async throws {
        let funding = MockHwFunding()
        funding.account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
        funding.maxSpendableError = MockHwFunding.TestError()
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: 2)

        let availability = try await signer.availability(walletId: "trezor:wallet")

        XCTAssertEqual(availability.available, 1_000_000 - 2 * 1200, "falls back to the reserve estimate")
    }

    func testAvailabilityFallsBackToReserveWhenAddressUnavailable() async throws {
        let funding = MockHwFunding()
        funding.account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: 2, address: nil)

        let availability = try await signer.availability(walletId: "trezor:wallet")

        XCTAssertTrue(funding.maxSpendableCalls.isEmpty, "no estimate without a destination address")
        XCTAssertEqual(availability.available, 1_000_000 - 2 * 1200)
    }

    // MARK: - Sign orchestration

    func testABroadcastThatAnswersLateIsKept() async throws {
        let funding = MockHwFunding()
        funding.broadcastDelay = 0.4
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (compose: 0.05, sign: 0.05))

        let result = try await signer.broadcastSignedFunding(funding.signedTx)

        XCTAssertEqual(result.txId, funding.broadcastTxId)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "a slow broadcast must not tear down the device session")
    }

    func testRawBroadcastErrorPropagatesUnwrapped() async {
        let funding = MockHwFunding()
        funding.broadcastError = MockHwFunding.TestError()
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.broadcastSignedFunding(funding.signedTx)
        } _: { error in
            XCTAssertTrue(error is MockHwFunding.TestError, "a real broadcast error must propagate unwrapped")
            XCTAssertNil(error as? HwTransferError)
        }
        XCTAssertTrue(connecting.staleDisconnects.isEmpty)
    }

    func testAlreadyKnownBroadcastUsesCoreReturnedTransactionId() async throws {
        let funding = MockHwFunding()
        funding.broadcastTxId = "core-derived-txid"
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting())
        let signed = HwFundingSignedTx(
            serializedTx: "rawtx",
            miningFeeSats: 141,
            feeRate: 1,
            totalSpent: 43186
        )

        let result = try await signer.broadcastSignedFunding(signed)

        XCTAssertEqual(result.txId, "core-derived-txid")
    }

    // MARK: - Vendor errors
}

/// Async variant of `XCTAssertThrowsError` using a plain (non-autoclosure) operation closure, so the
/// call site reads `await assertThrowsAsync { try await … }` without effect-hoisting ambiguity.
func assertThrowsAsync(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        try await operation()
        XCTFail(message.isEmpty ? "Expected error but none thrown" : message, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

@MainActor
extension XCTestCase {
    /// Waits until `condition` holds, failing at the caller's line if it does not within `timeout`, so a test cannot go on
    /// without the state it waited for.
    func eventually(
        _ description: String = "the condition holds",
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting until \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
