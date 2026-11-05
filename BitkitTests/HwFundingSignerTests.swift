@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

/// Device-signing orchestration coverage for `HwFundingSigner`, exercised in isolation from
/// `TransferViewModel` via the `HwTransferFunding` / `HwTransferConnecting` mocks.
@MainActor
final class HwFundingSignerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try Keychain.deleteAllRetainedHwSends()
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

    private func makeSigner(
        funding: MockHwFunding,
        connecting: MockHwConnecting,
        feeRate: UInt64? = 2,
        address: String? = "bc1qtest",
        timeouts: (compose: Double, sign: Double, broadcast: Double) = (compose: 5, sign: 5, broadcast: 5)
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
        let coordinator = HwSendCoordinator()
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
        let coordinator = HwSendCoordinator(walletId: "trezor:selected")

        coordinator.seedAvailable(walletId: "trezor:other", availableSats: 10000)
        XCTAssertEqual(coordinator.availableSats, 0)

        coordinator.seedAvailable(walletId: "trezor:selected", availableSats: 42000)
        XCTAssertEqual(coordinator.availableSats, 42000)
    }

    func testCoordinatorTracksFundingSourceRefresh() async {
        let funding = MockHwFunding()
        funding.maxSpendable = 42000
        let manager = HwWalletManager()
        let coordinator = HwSendCoordinator(
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
        let coordinator = HwSendCoordinator()
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
        let coordinator = HwSendCoordinator(
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
                satsPerVByte: 2,
                hasIncomingRequest: false
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
        let coordinator = HwSendCoordinator(
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
                satsPerVByte: 2,
                hasIncomingRequest: false
            )
            XCTFail("Expected preview preparation to fail")
        } catch {
            XCTAssertTrue(error is MockHwFunding.TestError)
        }

        XCTAssertFalse(coordinator.isFundingSourceLoading)
        XCTAssertFalse(coordinator.isPreviewLoading)
        XCTAssertEqual(coordinator.previewFeeSats, 0)
    }

    func testCoordinatorRetryReusesSignedPaymentAfterUncertainBroadcast() async throws {
        try await assertCoordinatorRetryReusesSignedPayment(error: HwTransferError.broadcastUncertain)
    }

    func testCoordinatorRoutesOnlyUnverifiedShopBroadcastToPending() async throws {
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: "merchant", billingPeriodStartsAt: nil
        )
        for (request, verified) in [(Optional(requestId), false), (Optional(requestId), true), (nil, false)] {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let coordinator = makeCoordinator(walletId: "trezor:original-ios-wallet", funding: funding, connecting: connecting)
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
            error: BroadcastError.ElectrumError(errorDetails: "offline")
        )
    }

    func testCoordinatorDeniedRetryPreservesAttemptedPayment() async throws {
        let broadcastErrors: [Error] = [
            HwTransferError.broadcastUncertain,
            BroadcastError.ElectrumError(errorDetails: "offline"),
        ]

        for broadcastError in broadcastErrors {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(walletId: "trezor:original-ios-wallet", funding: funding, connecting: connecting)
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
        let coordinator = makeCoordinator(walletId: "trezor:original-ios-wallet", funding: funding, connecting: MockHwConnecting())

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

    func testCoordinatorCancelKeepsSignedPaymentAfterFailedBroadcast() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: connecting)
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "offline")

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

        XCTAssertTrue(coordinator.hasPendingBroadcast)

        funding.broadcastError = nil
        _ = try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2
        )

        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
    }

    func testCoordinatorDeniedFirstAttemptReleasesPreparedPaymentForRetry() async throws {
        for authorizationError in [MockHwFunding.TestError() as Error, CancellationError()] {
            let funding = MockHwFunding()
            let manager = HwWalletManager()
            let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: MockHwConnecting())
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
                let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: MockHwConnecting())
                if hadPriorAttempt {
                    funding.broadcastError = HwTransferError.broadcastUncertain
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

    func testCoordinatorUnknownBroadcastFailureRemainsUncertainAndKeepsPendingPayment() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: MockHwConnecting())
        var failureOutcomes: [PrivatePaymentListSendOutcome] = []
        funding.broadcastError = MockHwFunding.TestError()

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                afterFailure: { failureOutcomes.append($0) }
            )
        }

        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(failureOutcomes, [.uncertain])

        funding.broadcastError = nil
        _ = try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            beforeFirstBroadcast: { _ in XCTFail("An attempted payment must not be prepared again") },
            afterFailure: { failureOutcomes.append($0) }
        )

        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
        XCTAssertEqual(failureOutcomes, [.uncertain])
    }

    func testCoordinatorRetriesPreparationFailureBeforeBroadcast() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: MockHwConnecting())
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
        let coordinator = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: connecting)
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

    // MARK: - Retained ordinary sends

    private enum Failure {
        static let unknown = BroadcastError.ElectrumError(errorDetails: "Broadcast failed: response lost")
        static let refused = BroadcastError.ElectrumError(errorDetails: "Broadcast failed: min relay fee not met")
        static let spent = BroadcastError.ElectrumError(errorDetails: "Broadcast failed: bad-txns-inputs-missingorspent")
        static let connect = BroadcastError.ElectrumError(errorDetails: "Failed to connect to Electrum: offline")
    }

    private func send(
        _ coordinator: HwSendCoordinator,
        address: String = "bc1qtest",
        sats: UInt64 = 42000,
        satsPerVByte: UInt64 = 2
    ) async throws {
        _ = try await coordinator.signAndBroadcast(manager: HwWalletManager(), address: address, sats: sats, satsPerVByte: satsPerVByte)
    }

    private func storeCorruptRetainedSend(walletId: String = "jade:wallet") throws -> Data {
        let corrupt = Data("not json".utf8)
        let key = KeychainEntryType.hwRetainedSend(walletId: walletId)
        try Keychain.upsert(key: key, data: corrupt)
        addTeardownBlock { try? Keychain.delete(key: key) }
        return corrupt
    }

    private func failSend(
        _ coordinator: HwSendCoordinator,
        address: String = "bc1qtest",
        sats: UInt64 = 42000,
        satsPerVByte: UInt64 = 2
    ) async {
        await assertThrowsAsync {
            try await self.send(coordinator, address: address, sats: sats, satsPerVByte: satsPerVByte)
        }
    }

    private func assertSingleSignature(_ funding: MockHwFunding, broadcasts: Int, line: UInt = #line) {
        XCTAssertEqual(funding.signCalls, 1, line: line)
        XCTAssertEqual(funding.composeCalls.count, 1, line: line)
        XCTAssertEqual(funding.broadcastTransactions, Array(repeating: funding.signedTx.serializedTx, count: broadcasts), line: line)
    }

    func testRetainedSendOutlivesTheSheetAndRebroadcastsOriginalBytes() async throws {
        let errors: [Error] = [
            Failure.unknown, BroadcastError.TaskError(errorDetails: "task failed"), HwTransferError.broadcastUncertain, MockHwFunding.TestError(),
        ]
        for error in errors {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let service = HwRetainedSendService.inMemory()
            funding.broadcastError = error
            await failSend(makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service))

            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(record, HwRetainedSend(
                walletId: "jade:wallet", address: "bc1qtest", sats: 42000, serializedTx: "rawtx",
                miningFeeSats: 141, feeRate: 1, totalSpent: 43186
            ))

            funding.broadcastError = nil
            let connects = connecting.ensureCalls
            let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
            let status = await reopened.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
            XCTAssertEqual(status, .retry(funding.signedTx))
            _ = try await reopened.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                beforeFirstBroadcast: { _ in XCTFail("A retained payment must not be prepared again") }
            )

            assertSingleSignature(funding, broadcasts: 2)
            XCTAssertEqual(connecting.ensureCalls, connects, "A retry must not contact the device")
            let released = try await service.record(walletId: "jade:wallet")
            XCTAssertNil(released)
        }
    }

    func testBroadcastTimeoutThenLeavingRebroadcastsOriginalBytes() async throws {
        let funding = MockHwFunding()
        funding.broadcastDelay = 0.4
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service, broadcastTimeout: 0.05
        )

        await assertThrowsAsync { try await self.send(coordinator) } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertTrue(coordinator.canLeave)
        coordinator.cancel()
        XCTAssertTrue(coordinator.hasPendingBroadcast)

        funding.broadcastDelay = 0
        try await send(coordinator)

        assertSingleSignature(funding, broadcasts: 2)
    }

    func testChangedFeeOnTheSamePaymentRebroadcastsOriginalBytes() async throws {
        for reopensSheet in [false, true] {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let original = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            funding.broadcastError = Failure.unknown
            await failSend(original)

            funding.broadcastError = nil
            let retry = reopensSheet
                ? makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
                : original
            _ = try await retry.preparePreview(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 9, hasIncomingRequest: false
            )
            let status = await retry.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
            XCTAssertEqual(status, .retry(funding.signedTx))
            try await send(retry, satsPerVByte: 9)

            assertSingleSignature(funding, broadcasts: 2)
        }
    }

    func testPreviewOfTheRetainedPaymentSkipsCompositionEvenWhenItWouldFail() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        funding.broadcastError = Failure.unknown
        await failSend(makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service))
        funding.composeError = MockHwFunding.TestError()
        let connects = connecting.ensureCalls

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
        reopened.selectWallet("trezor:other")
        reopened.selectWallet("jade:wallet", showsLoading: true)
        let fee = try await reopened.preparePreview(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 99, hasIncomingRequest: false
        )

        XCTAssertEqual(fee, funding.signedTx.miningFeeSats)
        XCTAssertEqual(reopened.previewFeeSats, funding.signedTx.miningFeeSats)
        XCTAssertFalse(reopened.isFundingSourceLoading)
        XCTAssertFalse(reopened.isPreviewLoading)
        XCTAssertTrue(funding.estimateCalls.isEmpty)
        XCTAssertEqual(connecting.ensureCalls, connects, "A preview must not contact the device")
        assertSingleSignature(funding, broadcasts: 1)
    }

    func testPreviewOfAnotherPaymentStillComposesAndCanFail() async throws {
        let payments: [(address: String, sats: UInt64)] = [("bc1qother", 42000), ("bc1qtest", 50000)]
        for payment in payments {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            funding.broadcastError = Failure.unknown
            await failSend(coordinator)

            funding.composeError = MockHwFunding.TestError()
            await assertThrowsAsync {
                _ = try await coordinator.preparePreview(
                    manager: HwWalletManager(), address: payment.address, sats: payment.sats, satsPerVByte: 9, hasIncomingRequest: false
                )
            } _: { error in
                XCTAssertTrue(error is MockHwFunding.TestError)
            }
            XCTAssertEqual(funding.estimateCalls.count, 1)
            XCTAssertEqual(coordinator.previewFeeSats, 0)

            funding.composeError = nil
            let fee = try await coordinator.preparePreview(
                manager: HwWalletManager(), address: payment.address, sats: payment.sats, satsPerVByte: 9, hasIncomingRequest: false
            )
            XCTAssertEqual(fee, funding.funding.miningFeeSats)
            XCTAssertEqual(funding.estimateCalls.count, 2)
        }
    }

    func testPreviewComposesWhenTheRetainedSendCannotBeRetried() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: HwRetainedSendService(store: store)
        )
        funding.broadcastErrors = [Failure.unknown, Failure.refused]
        await failSend(coordinator)
        _ = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 9, hasIncomingRequest: true
        )
        XCTAssertEqual(funding.estimateCalls.count, 1, "A Shop payment never reuses an ordinary retained send")

        await failSend(coordinator)
        _ = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 9, hasIncomingRequest: false
        )
        XCTAssertEqual(funding.estimateCalls.count, 2, "A refused retry goes through the warning and signs anew")

        store.setFailures(load: true)
        _ = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 9, hasIncomingRequest: false
        )
        XCTAssertEqual(funding.estimateCalls.count, 3, "An unreadable store is not a retry")
    }

    func testRetainedRetrySatsOnlyCoversARetryToTheSameAddress() async {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: HwRetainedSendService(store: store)
        )
        let noRecord = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: false)
        XCTAssertNil(noRecord)

        funding.broadcastError = Failure.unknown
        await failSend(coordinator)

        let sameAddress = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: false)
        let otherAddress = await coordinator.retainedRetrySats(address: "bc1qother", hasIncomingRequest: false)
        let incoming = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: true)
        XCTAssertEqual(sameAddress, 42000)
        XCTAssertNil(otherAddress)
        XCTAssertNil(incoming)

        store.setFailures(load: true)
        let unreadable = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: false)
        XCTAssertNil(unreadable)
    }

    func testRetainedRetrySatsIsNilAfterARefusedRetry() async {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastErrors = [Failure.unknown, Failure.refused]
        await failSend(coordinator)
        await failSend(coordinator)

        let refused = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: false)
        XCTAssertNil(refused)
    }

    func testFirstAttemptRefusalReleasesAndTheNextAttemptSignsAnew() async throws {
        let errors: [Error] = [
            Failure.refused, Failure.spent,
            BroadcastError.InvalidHex(errorDetails: "bad hex"), BroadcastError.InvalidTransaction(errorDetails: "bad tx"),
        ]
        for error in errors {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            funding.broadcastError = error
            await failSend(coordinator)

            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertNil(record)
            XCTAssertFalse(coordinator.hasPendingBroadcast)

            funding.broadcastError = nil
            try await send(coordinator)
            XCTAssertEqual(funding.signCalls, 2)
        }
    }

    func testRetryRefusalKeepsTheRecordAndWarns() async throws {
        for refusal in [Failure.refused, Failure.spent] {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let service = HwRetainedSendService.inMemory()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
            funding.broadcastErrors = [Failure.unknown, refusal]
            await failSend(coordinator)
            await assertThrowsAsync {
                try await self.send(coordinator)
            } _: { error in
                XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
            }

            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(record?.retryWasRefused, true)
            XCTAssertEqual(record?.serializedTx, funding.signedTx.serializedTx)
            XCTAssertTrue(coordinator.hasPendingBroadcast)
            XCTAssertFalse(coordinator.isBroadcastUnresolved)
            let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
            XCTAssertEqual(status, .blocking)
            assertSingleSignature(funding, broadcasts: 2)
        }
    }

    func testFirstAttemptConnectFailureLeavesNoRecordAndRetriesInThisSheet() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.connect
        await failSend(coordinator)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(record)
        XCTAssertTrue(coordinator.hasPendingBroadcast, "The bytes stay in memory for Retry in this sheet")
        XCTAssertTrue(coordinator.canLeave)
        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .none)

        funding.broadcastError = nil
        try await send(coordinator)
        assertSingleSignature(funding, broadcasts: 2)
    }

    func testFirstAttemptConnectFailureDropsBytesOnLeave() async throws {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = Failure.connect
        await failSend(coordinator)

        coordinator.cancel()

        XCTAssertFalse(coordinator.hasPendingBroadcast)
        funding.broadcastError = nil
        try await send(coordinator)
        XCTAssertEqual(funding.signCalls, 2)
    }

    func testConnectFailureOnRetryKeepsTheRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastErrors = [Failure.unknown, Failure.connect, nil]
        await failSend(coordinator)
        await failSend(coordinator)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.retryWasRefused, false)
        coordinator.cancel()
        XCTAssertTrue(coordinator.hasPendingBroadcast)

        try await send(coordinator)
        assertSingleSignature(funding, broadcasts: 3)
    }

    func testDifferentPaymentWarnsWithZeroDeviceContact() async throws {
        for (address, sats) in [("bc1qother", UInt64(42000)), ("bc1qtest", UInt64(50000))] {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let original = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            funding.broadcastError = Failure.unknown
            await failSend(original)
            funding.broadcastError = nil

            let connecting = MockHwConnecting()
            let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
            for coordinator in [original, reopened] {
                let status = await coordinator.retainedSendStatus(address: address, sats: sats, hasIncomingRequest: false)
                XCTAssertEqual(status, .blocking)
                await assertThrowsAsync {
                    try await self.send(coordinator, address: address, sats: sats)
                } _: { error in
                    XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
                }
            }

            XCTAssertEqual(connecting.ensureCalls, 0)
            assertSingleSignature(funding, broadcasts: 1)
            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(record?.address, "bc1qtest")
        }
    }

    func testConsentThenSignsAndKeepsTheRecordUntilThen() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        let original = try await service.record(walletId: "jade:wallet")

        coordinator.consentToNewSignature(address: "bc1qother", sats: 50000)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
        XCTAssertTrue(store.deletedWalletIds.isEmpty)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        let status = await coordinator.retainedSendStatus(address: "bc1qother", sats: 50000, hasIncomingRequest: false)
        XCTAssertEqual(status, .none)
        try await send(coordinator, address: "bc1qother", sats: 50000)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.composeCalls.last?.address, "bc1qother")
    }

    func testConsentCannotBeGrantedDuringAnInFlightBroadcast() async throws {
        let funding = MockHwFunding()
        let broadcast = AsyncGate()
        funding.broadcastGate = broadcast
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        let payment = Task { try await self.send(coordinator) }
        await waitUntil { funding.broadcastCalls == 1 }

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNotNil(record)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        broadcast.open()
        await assertThrowsAsync { try await payment.value }
        let rebroadcastTx = await coordinator.retainedRebroadcastTx(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(rebroadcastTx, funding.signedTx)
    }

    func testSuccessReleasesARecordWrittenBeforeDispatch() async throws {
        let funding = MockHwFunding()
        let broadcast = AsyncGate()
        funding.broadcastGate = broadcast
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        let payment = Task { try await self.send(coordinator) }
        await waitUntil { funding.broadcastCalls == 1 }

        let duringDispatch = try await service.record(walletId: "jade:wallet")
        XCTAssertNotNil(duringDispatch)

        broadcast.open()
        try await payment.value
        let afterSuccess = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(afterSuccess)
    }

    // MARK: Observed retained sends

    private let observableTx = HwFundingSignedTx(
        serializedTx: "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300",
        miningFeeSats: 141,
        feeRate: 1,
        totalSpent: 43186
    )

    private func markObserved(_ service: HwRetainedSendService, walletId: String = "jade:wallet") async throws {
        try await service.markObserved(walletId: walletId, txIds: [SignedTransactionId.fromHex(observableTx.serializedTx)])
    }

    /// A first attempt that fails with an unknown outcome, whose transaction the watcher then sees.
    private func failThenObserve(
        funding: MockHwFunding,
        connecting: MockHwConnecting? = nil,
        service: HwRetainedSendService
    ) async throws -> HwSendCoordinator {
        funding.signedTx = observableTx
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: connecting ?? MockHwConnecting(), retainedSends: service
        )
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        try await markObserved(service)
        return coordinator
    }

    func testForwardThenErrorThenObservedThenRetryRebroadcastsAndReleases() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, connecting: connecting, service: service)
        let connects = connecting.ensureCalls

        XCTAssertTrue(coordinator.hasPendingBroadcast, "The sign button stays Retry in the open sheet")
        let result = try await coordinator.signAndBroadcast(manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2)

        XCTAssertEqual(result.txId, funding.broadcastTxId)
        assertSingleSignature(funding, broadcasts: 2)
        XCTAssertEqual(connecting.ensureCalls, connects, "A retry must not contact the device")
        let released = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(released)
    }

    func testAnyRetryFailureOfAnObservedRecordIsASuccess() async throws {
        let errors: [Error] = [
            Failure.refused, Failure.spent, Failure.unknown, Failure.connect, HwTransferError.broadcastUncertain,
            BroadcastError.TaskError(errorDetails: "task"),
        ]
        for error in errors {
            let funding = MockHwFunding()
            let connecting = MockHwConnecting()
            let service = HwRetainedSendService.inMemory()
            let coordinator = try await failThenObserve(funding: funding, connecting: connecting, service: service)
            let connects = connecting.ensureCalls
            funding.broadcastError = error
            var afterBroadcastTxId: String?

            let result = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                afterBroadcast: { afterBroadcastTxId = $0.txId }
            )

            let expectedTxId = try SignedTransactionId.fromHex(observableTx.serializedTx)
            XCTAssertEqual(result, HwFundingBroadcastResult(txId: expectedTxId, miningFeeSats: 141, feeRate: 1, totalSpent: 43186), "\(error)")
            XCTAssertEqual(afterBroadcastTxId, expectedTxId, "\(error)")
            XCTAssertFalse(coordinator.isBroadcastUnresolved)
            assertSingleSignature(funding, broadcasts: 2)
            XCTAssertEqual(connecting.ensureCalls, connects, "\(error)")
            let released = try await service.record(walletId: "jade:wallet")
            XCTAssertNil(released, "\(error)")
        }
    }

    func testAnyFirstAttemptFailureOfAnObservedRecordIsASuccessWithOneSignature() async throws {
        let errors: [Error] = [Failure.refused, Failure.spent, Failure.unknown, Failure.connect, HwTransferError.broadcastUncertain]
        for error in errors {
            let funding = MockHwFunding()
            funding.signedTx = observableTx
            let broadcast = AsyncGate()
            funding.broadcastGate = broadcast
            funding.broadcastError = error
            let service = HwRetainedSendService.inMemory()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            let payment = Task {
                try await coordinator.signAndBroadcast(manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2)
            }
            await waitUntil { funding.broadcastCalls == 1 }

            try await markObserved(service)
            broadcast.open()
            let result = try await payment.value

            try XCTAssertEqual(result.txId, SignedTransactionId.fromHex(observableTx.serializedTx), "\(error)")
            assertSingleSignature(funding, broadcasts: 1)
            let released = try await service.record(walletId: "jade:wallet")
            XCTAssertNil(released, "\(error)")
        }
    }

    func testFirstAttemptRefusalOfAnUnobservedRecordStillReleasesAsAFailure() async throws {
        let funding = MockHwFunding()
        funding.signedTx = observableTx
        funding.broadcastError = Failure.refused
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)

        await failSend(coordinator)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(record)
    }

    func testObservedRecordIsNotCompletedByACancelledAttempt() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, service: service)
        funding.broadcastError = CancellationError()

        await assertThrowsAsync {
            try await self.send(coordinator)
        } _: { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.observed, true)
    }

    func testRetryThatWasRefusedBeforeBeingObservedStaysARetryAndSucceeds() async throws {
        let funding = MockHwFunding()
        funding.signedTx = observableTx
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastErrors = [Failure.unknown, Failure.spent, Failure.spent]
        await failSend(coordinator)
        await failSend(coordinator)
        try await markObserved(service)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.retryWasRefused, true)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        let rebroadcast = await coordinator.retainedRebroadcastTx(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(rebroadcast, observableTx, "The sign button stays Retry and needs no current fee rate")

        try await send(coordinator)

        assertSingleSignature(funding, broadcasts: 3)
        let released = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(released)
    }

    func testReopenedSamePaymentWithAnObservedRecordBlocksWithoutDeviceContact() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        _ = try await failThenObserve(funding: funding, connecting: connecting, service: service)
        let connects = connecting.ensureCalls

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
        let status = await reopened.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)

        XCTAssertEqual(status, .blocking)
        XCTAssertEqual(connecting.ensureCalls, connects)
        assertSingleSignature(funding, broadcasts: 1)
    }

    func testConsentOverAnObservedRecordSignsTheSamePaymentAnew() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        _ = try await failThenObserve(funding: funding, service: service)

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        reopened.consentToNewSignature(address: "bc1qtest", sats: 42000)

        let status = await reopened.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .none)
        funding.signedTx = newSignedTx
        try await send(reopened)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions.last, newSignedTx.serializedTx)
    }

    func testYesSendOverAFeeLockedReviewShowsTheCurrentFeeAndTheNextSwipeSignsWithoutWarning() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        funding.signedTx = observableTx
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil

        let locked = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(locked.retrySignedTx, observableTx)
        try await markObserved(service)
        let warned = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(warned, .blocking)
        let original = try await service.record(walletId: "jade:wallet")

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        coordinator.discardPreviewFee()

        // The fee reload must not lock again from the record that is still there.
        let reloaded = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        let rebroadcastTx = await coordinator.retainedRebroadcastTx(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        let retrySats = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: false)
        XCTAssertEqual(reloaded, .none, "No lock and no second warning")
        XCTAssertNil(rebroadcastTx, "Neither the fee nor the Retry label comes from the old bytes")
        XCTAssertNil(retrySats)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        XCTAssertEqual(coordinator.previewFeeSats, 0)
        let fee = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 9, hasIncomingRequest: false
        )
        XCTAssertEqual(funding.estimateCalls.count, 1)
        XCTAssertEqual(fee, funding.funding.miningFeeSats)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)

        funding.signedTx = newSignedTx
        try await send(coordinator, satsPerVByte: 9)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.composeCalls.last?.satsPerVByte, 9, "Signs the fee on screen")
        XCTAssertEqual(funding.broadcastTransactions.last, newSignedTx.serializedTx)
    }

    func testRetainedSendLocksNoFeeForAPaymentThatNoLongerMatches() async {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = MockHwFunding.TestError()
        await failSend(coordinator)

        let same = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertNotNil(same.retrySignedTx)
        for payment in [(address: "bc1qother", sats: UInt64(42000)), (address: "bc1qtest", sats: UInt64(50000))] {
            let status = await coordinator.retainedSendStatus(address: payment.address, sats: payment.sats, hasIncomingRequest: false)
            let rebroadcastTx = await coordinator.retainedRebroadcastTx(address: payment.address, sats: payment.sats, hasIncomingRequest: false)
            XCTAssertNil(status.retrySignedTx)
            XCTAssertNil(rebroadcastTx)
        }
    }

    func testDifferentPaymentWithAnObservedRecordSignsWithNoWarning() async throws {
        let payments: [(address: String, sats: UInt64)] = [("bc1qother", 42000), ("bc1qtest", 50000)]
        for reopensSheet in [false, true] {
            for payment in payments {
                let funding = MockHwFunding()
                let service = HwRetainedSendService.inMemory()
                let original = try await failThenObserve(funding: funding, service: service)
                let coordinator = reopensSheet
                    ? makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
                    : original

                let status = await coordinator.retainedSendStatus(address: payment.address, sats: payment.sats, hasIncomingRequest: false)
                XCTAssertEqual(status, .none)
                try await send(coordinator, address: payment.address, sats: payment.sats)

                XCTAssertEqual(funding.signCalls, 2)
                XCTAssertEqual(funding.composeCalls.last?.address, payment.address)
                XCTAssertEqual(funding.composeCalls.last?.sats, payment.sats)
                let record = try await service.record(walletId: "jade:wallet")
                XCTAssertNil(record)
            }
        }
    }

    func testPreviewOfADifferentPaymentDropsTheObservedAttemptSoTheButtonIsNotRetry() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, service: service)
        XCTAssertTrue(coordinator.hasPendingBroadcast)

        _ = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qother", sats: 50000, satsPerVByte: 2, hasIncomingRequest: false
        )

        XCTAssertFalse(coordinator.hasPendingBroadcast)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNotNil(record, "The record is replaced only once that send has signed")
    }

    func testFailedNewSendOverAnObservedRecordLeavesTheOriginalGuarded() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        let coordinator = try await failThenObserve(funding: funding, connecting: connecting, service: service)
        let original = try await service.record(walletId: "jade:wallet")

        connecting.connectError = MockHwFunding.TestError()
        await failSend(coordinator, address: "bc1qother")
        connecting.connectError = nil

        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertTrue(store.deletedWalletIds.isEmpty)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
        let status = await reopened.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking)
        try await send(reopened)
        XCTAssertEqual(funding.signCalls, 1, "Repeating the original rebroadcasts it and never signs again")
        XCTAssertEqual(funding.broadcastTransactions.last, observableTx.serializedTx)
    }

    func testFailedReplaceWriteOverAnObservedRecordDoesNotDispatch() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        _ = try await failThenObserve(funding: funding, service: service)
        let original = try await service.record(walletId: "jade:wallet")
        funding.signedTx = newSignedTx
        store.setFailures(save: true)

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        await assertThrowsAsync {
            try await self.send(reopened, address: "bc1qother")
        } _: { error in
            XCTAssertTrue(error is MockHwRetainedSendStore.StoreError, "\(error)")
        }

        store.setFailures()
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastCalls, 1, "The new bytes never go out")
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
    }

    func testNotSubmittedReplacementPutsTheOriginalBackForBothReplacementKinds() async throws {
        for consents in [false, true] {
            let funding = MockHwFunding()
            let store = MockHwRetainedSendStore()
            let service = HwRetainedSendService(store: store)
            _ = try await failThenObserve(funding: funding, service: service)
            let original = try await service.record(walletId: "jade:wallet")
            funding.signedTx = newSignedTx

            let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            if consents {
                reopened.consentToNewSignature(address: "bc1qother", sats: 42000)
            }
            await assertThrowsAsync {
                _ = try await reopened.signAndBroadcast(
                    manager: HwWalletManager(), address: "bc1qother", sats: 42000, satsPerVByte: 2,
                    markSignedPaymentRefused: { _, _ in throw MockHwFunding.TestError() }
                )
            }

            XCTAssertEqual(funding.broadcastCalls, 1)
            XCTAssertTrue(store.deletedWalletIds.isEmpty)
            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(record, original)
        }
    }

    func testConsentThenSigningIdenticalBytesThatAreNotSubmittedKeepsTheRecord() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        _ = try await failThenObserve(funding: funding, service: service)
        let original = try await service.record(walletId: "jade:wallet")

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        reopened.consentToNewSignature(address: "bc1qtest", sats: 42000)
        await assertThrowsAsync {
            _ = try await reopened.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                markSignedPaymentRefused: { _, _ in throw MockHwFunding.TestError() }
            )
        }

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertTrue(store.deletedWalletIds.isEmpty)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
    }

    // MARK: Consent to a new signature

    private let newSignedTx = HwFundingSignedTx(serializedTx: "newtx", miningFeeSats: 300, feeRate: 9, totalSpent: 42300)

    private func consentAndSignIdenticalBytes(
        funding: MockHwFunding,
        service: HwRetainedSendService,
        failure: Error
    ) async throws -> (coordinator: HwSendCoordinator, error: Error?) {
        let original = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastErrors = [Failure.unknown]
        await failSend(original)

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        reopened.consentToNewSignature(address: "bc1qtest", sats: 42000)
        funding.broadcastErrors = [failure]
        var thrown: Error?
        await assertThrowsAsync {
            try await self.send(reopened)
        } _: { error in
            thrown = error
        }

        XCTAssertEqual(funding.signCalls, 2, "Consent signs anew")
        XCTAssertEqual(funding.broadcastTransactions, Array(repeating: funding.signedTx.serializedTx, count: 2))
        return (reopened, thrown)
    }

    func testConsentThenSigningIdenticalBytesThenRefusalKeepsTheRecordAndWarns() async throws {
        for refusal in [Failure.refused, Failure.spent] {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()

            let (coordinator, error) = try await consentAndSignIdenticalBytes(funding: funding, service: service, failure: refusal)

            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(record?.serializedTx, funding.signedTx.serializedTx)
            XCTAssertEqual(record?.retryWasRefused, true)
            XCTAssertTrue(coordinator.hasPendingBroadcast)
            let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
            XCTAssertEqual(status, .blocking)
        }
    }

    func testConsentThenSigningIdenticalBytesThenConnectFailureKeepsTheRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()

        let (coordinator, error) = try await consentAndSignIdenticalBytes(funding: funding, service: service, failure: Failure.connect)

        XCTAssertEqual(error.map { "\($0)" }, "\(Failure.connect)", "A retry's connect failure keeps its own error")
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.serializedTx, funding.signedTx.serializedTx)
        XCTAssertEqual(record?.retryWasRefused, false)
        XCTAssertTrue(coordinator.hasPendingBroadcast)

        funding.broadcastErrors = []
        try await send(coordinator)
        XCTAssertEqual(funding.signCalls, 2, "Retry rebroadcasts the kept bytes")
        XCTAssertEqual(funding.broadcastTransactions, Array(repeating: funding.signedTx.serializedTx, count: 3))
    }

    func testConsentThenDeviceRejectionKeepsTheRecordAndWarnsAgain() async throws {
        let payments: [(address: String, sats: UInt64)] = [("bc1qother", 42000), ("bc1qtest", 42000)]
        for payment in payments {
            for isObserved in [false, true] {
                let funding = MockHwFunding()
                let service = HwRetainedSendService.inMemory()
                funding.signedTx = observableTx
                let original = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
                funding.broadcastError = Failure.unknown
                await failSend(original)
                funding.broadcastError = nil
                if isObserved {
                    try await markObserved(service)
                }
                try await service.markRetryRefused(walletId: "jade:wallet")
                let before = try await service.record(walletId: "jade:wallet")

                original.consentToNewSignature(address: payment.address, sats: payment.sats)
                funding.signError = MockHwFunding.TestError()
                await failSend(original, address: payment.address, sats: payment.sats)
                funding.signError = nil

                XCTAssertEqual(funding.signCalls, 2)
                XCTAssertEqual(funding.broadcastCalls, 1)
                let after = try await service.record(walletId: "jade:wallet")
                XCTAssertEqual(after, before)
                let status = await original.retainedSendStatus(address: payment.address, sats: payment.sats, hasIncomingRequest: false)
                XCTAssertEqual(status, isObserved && payment.address == "bc1qother" ? .none : .blocking)
            }
        }
    }

    func testConsentThenLeavingWarnsAgainWithNoSigning() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        let before = try await service.record(walletId: "jade:wallet")
        let connects = connecting.ensureCalls

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        coordinator.cancel()

        let status = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking)
        await assertThrowsAsync {
            try await self.send(coordinator, address: "bc1qother")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(connecting.ensureCalls, connects)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, before)
    }

    func testLeavingWhileConnectingAfterConsentKeepsTheRecord() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        let before = try await service.record(walletId: "jade:wallet")
        let connect = AsyncGate()
        connecting.connectGate = connect
        let connects = connecting.ensureCalls

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        let payment = Task { try await self.send(coordinator, address: "bc1qother") }
        await waitUntil { connecting.ensureCalls == connects + 1 }
        coordinator.cancel()
        connect.open()
        await assertThrowsAsync { try await payment.value }

        XCTAssertEqual(funding.signCalls, 1)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, before)
    }

    func testNewCoordinatorHasNoConsent() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, service: service)
        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)

        let restarted = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        let status = await restarted.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)

        XCTAssertEqual(status, .blocking)
    }

    func testConsentIsUsedByOneAttempt() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        connecting.connectError = MockHwFunding.TestError()
        await failSend(coordinator, address: "bc1qother")
        connecting.connectError = nil

        await assertThrowsAsync {
            try await self.send(coordinator, address: "bc1qother")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.signCalls, 1)
    }

    func testConsentCoversOnlyItsOwnPaymentAndADifferentRequestEndsIt() async {
        let others: [(address: String, sats: UInt64)] = [("bc1qother", 50000), ("bc1qtest", 42000)]
        for other in others {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            funding.broadcastError = Failure.unknown
            await failSend(coordinator)
            funding.broadcastError = nil

            coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
            let different = await coordinator.retainedSendStatus(address: other.address, sats: other.sats, hasIncomingRequest: false)
            let back = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)

            XCTAssertNotEqual(different, .none)
            XCTAssertEqual(back, .blocking)
        }
    }

    func testSwitchingWalletEndsConsent() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, service: service)
        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)

        coordinator.selectWallet("trezor:wallet")
        coordinator.selectWallet("jade:wallet")

        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking)
    }

    func testPassphrasePromptKeepsConsentForTheSameAttemptUntilDismissed() async throws {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, connecting: connecting, service: service)
        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        connecting.connectError = HwPassphraseError.required
        await failSend(coordinator)
        connecting.connectError = nil
        funding.signedTx = newSignedTx

        coordinator.dismissPassphrase()
        let dismissed = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(dismissed, .blocking)

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        connecting.connectError = HwPassphraseError.required
        await failSend(coordinator)
        connecting.connectError = nil

        try await send(coordinator)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions.last, newSignedTx.serializedTx)
    }

    func testConsentReplacesTheRecordOnlyAfterSigningAndBeforeDispatch() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        let original = try await service.record(walletId: "jade:wallet")

        funding.signedTx = newSignedTx
        let sign = AsyncGate()
        funding.signGate = sign
        let broadcast = AsyncGate()
        funding.broadcastGate = broadcast
        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        let payment = Task { try await self.send(coordinator, address: "bc1qother") }

        await waitUntil { funding.signCalls == 2 }
        let whileSigning = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(whileSigning, original)

        sign.open()
        await waitUntil { funding.broadcastCalls == 2 }
        let whileDispatching = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(whileDispatching?.serializedTx, newSignedTx.serializedTx)
        XCTAssertEqual(whileDispatching?.address, "bc1qother")
        XCTAssertTrue(store.deletedWalletIds.isEmpty, "Replaced in one write, with no delete in between")

        broadcast.open()
        try await payment.value
    }

    func testFailedReplaceWriteWithConsentDoesNotDispatch() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        let original = try await service.record(walletId: "jade:wallet")
        funding.signedTx = newSignedTx

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        store.setFailures(save: true)
        await failSend(coordinator, address: "bc1qother")
        store.setFailures()

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertTrue(store.deletedWalletIds.isEmpty)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
        let status = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking)
    }

    // MARK: Restoring a replaced record

    func testFirstAttemptRefusalOfTheNewBytesRestoresTheOldRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        let original = try await service.record(walletId: "jade:wallet")
        funding.signedTx = newSignedTx
        funding.broadcastError = Failure.refused

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        await failSend(coordinator, address: "bc1qother")

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
        XCTAssertEqual(record?.serializedTx, "rawtx")
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        var status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status.retrySignedTx?.serializedTx, "rawtx")
        status = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking, "The consent is used, so another signature needs a new warning")

        funding.broadcastError = nil
        let signatures = funding.signCalls
        try await send(coordinator)
        XCTAssertEqual(funding.signCalls, signatures)
        XCTAssertEqual(funding.broadcastTransactions.last, "rawtx")
    }

    func testRefusalOfTheNewBytesRestoresAWarningOldRecordAsItWas() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastErrors = [Failure.unknown, Failure.refused]
        await failSend(coordinator)
        await failSend(coordinator)
        let original = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(original?.retryWasRefused, true)
        funding.signedTx = newSignedTx
        funding.broadcastError = Failure.refused

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        await failSend(coordinator)

        XCTAssertEqual(funding.signCalls, 2)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking)
    }

    func testFirstAttemptConnectFailureRestoresTheOldRecordAndRetryKeepsTheNewBytes() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        let original = try await service.record(walletId: "jade:wallet")
        funding.signedTx = newSignedTx
        funding.broadcastError = Failure.connect

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        await failSend(coordinator, address: "bc1qother")

        var record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        let oldStatus = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(oldStatus.retrySignedTx?.serializedTx, "rawtx")
        let rebroadcast = await coordinator.retainedRebroadcastTx(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(rebroadcast, newSignedTx)

        // A second connect failure still restores, and the Retry never signs.
        await failSend(coordinator, address: "bc1qother")
        record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)

        funding.broadcastError = nil
        try await send(coordinator, address: "bc1qother", satsPerVByte: 9)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions.last, newSignedTx.serializedTx)
        record = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(record)
    }

    func testRetryOfTheSamePaymentAfterAConnectFailureSendsTheNewBytesNotTheRestoredOnes() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        let original = try await service.record(walletId: "jade:wallet")
        funding.signedTx = newSignedTx
        funding.broadcastError = Failure.connect

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        await failSend(coordinator)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)

        funding.broadcastError = nil
        try await send(coordinator)

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions.last, newSignedTx.serializedTx)
    }

    func testLeavingAfterAConnectFailureDropsTheNewBytesAndKeepsTheOldRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        let original = try await service.record(walletId: "jade:wallet")
        funding.signedTx = newSignedTx
        funding.broadcastError = Failure.connect
        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        await failSend(coordinator, address: "bc1qother")

        coordinator.cancel()

        XCTAssertFalse(coordinator.hasPendingBroadcast)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record, original)
        let rebroadcast = await coordinator.retainedRebroadcastTx(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertNil(rebroadcast)
        funding.broadcastError = nil
        await assertThrowsAsync {
            try await self.send(coordinator, address: "bc1qother")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.signCalls, 2, "A further signature needs a new warning")
    }

    func testFailureOfADifferentPaymentRestoresAnObservedOldRecord() async throws {
        for failure in [Failure.refused, Failure.connect] {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let coordinator = try await failThenObserve(funding: funding, service: service)
            let original = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(original?.observed, true)
            funding.signedTx = newSignedTx
            funding.broadcastError = failure

            await failSend(coordinator, address: "bc1qother")

            XCTAssertEqual(funding.signCalls, 2)
            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertEqual(record, original)
            XCTAssertEqual(record?.serializedTx, observableTx.serializedTx)
            let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
            XCTAssertEqual(status, .blocking)
        }
    }

    func testRetryAfterAConnectFailureOverAnObservedRecordSendsTheNewBytes() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, service: service)
        funding.signedTx = newSignedTx
        funding.broadcastError = Failure.connect
        await failSend(coordinator, address: "bc1qother")

        funding.broadcastError = nil
        try await send(coordinator, address: "bc1qother")

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions.last, newSignedTx.serializedTx)
    }

    func testFailedRestoreKeepsTheNewBytesAsTheRecord() async throws {
        for failure in [Failure.refused, Failure.connect] {
            for storeFailure in ["save", "load"] {
                let funding = MockHwFunding()
                let store = MockHwRetainedSendStore()
                let service = HwRetainedSendService(store: store)
                let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
                funding.broadcastError = Failure.unknown
                await failSend(coordinator)
                funding.signedTx = newSignedTx
                funding.broadcastError = failure
                let broadcast = AsyncGate()
                funding.broadcastGate = broadcast

                coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
                let payment = Task { try await self.send(coordinator, address: "bc1qother") }
                await waitUntil { funding.broadcastCalls == 2 }
                store.setFailures(load: storeFailure == "load", save: storeFailure == "save")
                broadcast.open()
                await assertThrowsAsync { try await payment.value }
                store.setFailures()

                XCTAssertTrue(store.deletedWalletIds.isEmpty)
                let record = try await service.record(walletId: "jade:wallet")
                XCTAssertEqual(record?.serializedTx, newSignedTx.serializedTx)
                XCTAssertEqual(record?.address, "bc1qother")
                let oldStatus = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
                XCTAssertEqual(oldStatus, .blocking)
            }
        }
    }

    func testNewBytesObservedDuringAFailedBroadcastCompleteAsSuccessWithNoRestore() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.signedTx = observableTx
        funding.broadcastError = Failure.refused
        let broadcast = AsyncGate()
        funding.broadcastGate = broadcast

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        let payment = Task { try await self.send(coordinator, address: "bc1qother") }
        await waitUntil { funding.broadcastCalls == 2 }
        try await markObserved(service)
        broadcast.open()
        try await payment.value

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(record)
    }

    func testUnknownOutcomeOfTheNewBytesKeepsThemAsTheRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.signedTx = newSignedTx

        coordinator.consentToNewSignature(address: "bc1qother", sats: 42000)
        await failSend(coordinator, address: "bc1qother")

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.serializedTx, newSignedTx.serializedTx)
        let status = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status.retrySignedTx, newSignedTx)
    }

    func testDifferentPaymentOverAnUnobservedRecordStaysBlocked() async {
        let funding = MockHwFunding()
        funding.signedTx = observableTx
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)

        let status = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .blocking)
        await assertThrowsAsync {
            try await self.send(coordinator, address: "bc1qother")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.signCalls, 1)
    }

    func testNewCoordinatorKeepsTheObservedFlag() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        _ = try await failThenObserve(funding: funding, service: service)

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        _ = await reopened.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.observed, true)
        XCTAssertEqual(record?.serializedTx, observableTx.serializedTx)
    }

    func testObservedRecordIsNotARetryForFundabilityGates() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = try await failThenObserve(funding: funding, service: service)

        let retrySats = await coordinator.retainedRetrySats(address: "bc1qtest", hasIncomingRequest: false)
        XCTAssertNil(retrySats)

        let fee = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 9, hasIncomingRequest: false
        )
        XCTAssertEqual(funding.estimateCalls.count, 1, "A genuine repeat composes at today's fee")
        XCTAssertEqual(fee, funding.funding.miningFeeSats)
    }

    func testSignScreenRebroadcastIsTheRecordOfTheSamePaymentOnly() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        _ = try await failThenObserve(funding: funding, service: service)

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        let same = await reopened.retainedRebroadcastTx(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        let other = await reopened.retainedRebroadcastTx(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        let incoming = await reopened.retainedRebroadcastTx(address: "bc1qtest", sats: 42000, hasIncomingRequest: true)

        XCTAssertEqual(same, observableTx)
        XCTAssertNil(other)
        XCTAssertNil(incoming)
    }

    func testWalletRemovalReleasesAndTheNextAttemptSignsAnew() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        funding.broadcastError = Failure.unknown
        await failSend(makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service))
        funding.broadcastError = nil

        try await service.release(walletId: "jade:wallet")

        let reopened = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        try await send(reopened, address: "bc1qother")
        XCTAssertEqual(funding.signCalls, 2)
    }

    func testAnotherHardwareWalletIsUnaffected() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        funding.broadcastError = Failure.unknown
        await failSend(makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service))
        funding.broadcastError = nil

        let other = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        let status = await other.retainedSendStatus(address: "bc1qother", sats: 50000, hasIncomingRequest: false)
        XCTAssertEqual(status, .none)
        try await send(other, address: "bc1qother", sats: 50000)

        XCTAssertEqual(funding.signCalls, 2)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.address, "bc1qtest")
        let otherRecord = try await service.record(walletId: "trezor:wallet")
        XCTAssertNil(otherRecord)
    }

    func testOrdinaryBroadcastFailureNeverLocksNavigation() async {
        let errors: [Error] = [
            Failure.unknown, Failure.refused, Failure.connect, HwTransferError.broadcastUncertain, BroadcastError.TaskError(errorDetails: "task"),
        ]
        for error in errors {
            let funding = MockHwFunding()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
            funding.broadcastErrors = [Failure.connect, error, error]
            for _ in 0 ..< 3 {
                await failSend(coordinator)
                XCTAssertFalse(coordinator.isBroadcastUnresolved)
                XCTAssertTrue(coordinator.canLeave)
            }
        }
    }

    func testRetainWriteFailureAbortsBeforeDispatch() async {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        store.setFailures(save: true)
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: HwRetainedSendService(store: store)
        )
        var outcomes: [PrivatePaymentListSendOutcome] = []

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                afterFailure: { outcomes.append($0) }
            )
        } _: { error in
            XCTAssertTrue(error is MockHwRetainedSendStore.StoreError, "\(error)")
        }

        XCTAssertEqual(funding.broadcastCalls, 0)
        XCTAssertEqual(outcomes, [.definitePreBroadcastFailure])
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        XCTAssertTrue(coordinator.canLeave)
    }

    func testUnreadableRecordFailsClosedBeforeDeviceContact() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let store = MockHwRetainedSendStore()
        store.setFailures(load: true)
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: HwRetainedSendService(store: store)
        )

        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        await failSend(coordinator)

        XCTAssertEqual(status, .blocking)
        XCTAssertEqual(connecting.ensureCalls, 0)
        XCTAssertEqual(funding.signCalls, 0)
    }

    func testCorruptEntryBlocksOnlyItsOwnWalletWithoutDeviceContact() async throws {
        let corrupt = try storeCorruptRetainedSend()
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()

        let blocked = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: HwRetainedSendService())
        let blockedStatus = await blocked.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(blockedStatus, .blocking)

        let other = makeCoordinator(walletId: "trezor:wallet", funding: funding, connecting: connecting, retainedSends: HwRetainedSendService())
        let otherStatus = await other.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(otherStatus, .none)

        XCTAssertEqual(connecting.ensureCalls, 0)
        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(try Keychain.load(key: .hwRetainedSend(walletId: "jade:wallet")), corrupt)
    }

    func testCorruptEntryFailsSigningClosedAndStaysInPlace() async throws {
        let corrupt = try storeCorruptRetainedSend()
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: HwRetainedSendService())

        await assertThrowsAsync {
            try await self.send(coordinator)
        } _: { error in
            guard case HwRetainedSendError.corruptStore = error else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(connecting.ensureCalls, 0)
        XCTAssertEqual(funding.signCalls, 0)
        XCTAssertEqual(funding.broadcastCalls, 0)
        XCTAssertEqual(try Keychain.load(key: .hwRetainedSend(walletId: "jade:wallet")), corrupt)
    }

    func testConsentReplacesACorruptEntryOnlyAfterSigning() async throws {
        let corrupt = try storeCorruptRetainedSend()
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: HwRetainedSendService()
        )

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(status, .none)

        funding.signError = MockHwFunding.TestError()
        await failSend(coordinator)
        funding.signError = nil
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(try Keychain.load(key: .hwRetainedSend(walletId: "jade:wallet")), corrupt, "Rejected on the device: nothing changes")
        let warned = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(warned, .blocking)

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.broadcastCalls, 1)
        let record = try await HwRetainedSendService().record(walletId: "jade:wallet")
        XCTAssertEqual(record?.serializedTx, funding.signedTx.serializedTx)
    }

    func testNotSubmittedOverACorruptEntryKeepsTheNewBytesAsTheGuard() async throws {
        _ = try storeCorruptRetainedSend()
        let funding = MockHwFunding()
        let service = HwRetainedSendService()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)

        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                markSignedPaymentRefused: { _, _ in throw MockHwFunding.TestError() }
            )
        }

        XCTAssertEqual(funding.broadcastCalls, 0)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.serializedTx, funding.signedTx.serializedTx)
    }

    func testReadFailureFailsClosedDespiteConsentAndRecoversOnItsOwn() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let store = MockHwRetainedSendStore()
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: connecting, retainedSends: HwRetainedSendService(store: store)
        )
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil
        let connects = connecting.ensureCalls

        store.setFailures(load: true)
        coordinator.consentToNewSignature(address: "bc1qtest", sats: 42000)
        let unreadable = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(unreadable, .blocking)
        await failSend(coordinator)
        XCTAssertEqual(connecting.ensureCalls, connects)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertTrue(store.deletedWalletIds.isEmpty)

        store.setFailures()
        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        guard case .retry = status else { return XCTFail("\(status)") }
    }

    func testNotSubmittedFirstAttemptReleasesTheRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                markSignedPaymentRefused: { _, _ in throw MockHwFunding.TestError() }
            )
        }

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(record)
        XCTAssertFalse(coordinator.hasPendingBroadcast)
        XCTAssertEqual(funding.broadcastCalls, 0)
    }

    func testNotSubmittedRetryKeepsTheRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                markSignedPaymentRefused: { _, _ in throw MockHwFunding.TestError() }
            )
        }

        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.retryWasRefused, false)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertEqual(funding.broadcastCalls, 1)
    }

    func testFailedReleaseBeforeDispatchKeepsTheAttemptWithoutLockingNavigation() async throws {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                markSignedPaymentRefused: { _, _ in
                    store.setFailures(delete: true)
                    throw MockHwFunding.TestError()
                }
            )
        }

        store.setFailures()
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNotNil(record)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertFalse(coordinator.isBroadcastUnresolved)
        XCTAssertTrue(coordinator.canLeave)
    }

    func testIncomingRequestReportsNoRetainedSendWithoutReadingTheStore() async {
        let funding = MockHwFunding()
        let store = MockHwRetainedSendStore()
        let coordinator = makeCoordinator(
            walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: HwRetainedSendService(store: store)
        )
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)

        let sameIncoming = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: true)
        let differentIncoming = await coordinator.retainedSendStatus(address: "bc1qother", sats: 50000, hasIncomingRequest: true)
        XCTAssertEqual(sameIncoming, .none)
        XCTAssertEqual(differentIncoming, .none)

        store.setFailures(load: true)
        let unreadableIncoming = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: true)
        let unreadableOrdinary = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        XCTAssertEqual(unreadableIncoming, .none)
        XCTAssertEqual(unreadableOrdinary, .blocking)
    }

    func testOnlyAnOrdinaryRetryStatusCarriesTheRetainedBytes() async {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)

        let retry = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)
        let blocking = await coordinator.retainedSendStatus(address: "bc1qother", sats: 42000, hasIncomingRequest: false)
        let incoming = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: true)
        XCTAssertEqual(retry.retrySignedTx, funding.signedTx)
        XCTAssertEqual(blocking, .blocking)
        XCTAssertNil(blocking.retrySignedTx)
        XCTAssertNil(incoming.retrySignedTx)
    }

    func testNoWalletReportsNoRetainedSend() async {
        let coordinator = HwSendCoordinator(retainedSends: .inMemory())

        let status = await coordinator.retainedSendStatus(address: "bc1qtest", sats: 42000, hasIncomingRequest: false)

        XCTAssertEqual(status, .none)
    }

    func testKeptOrdinaryFailureThatIsNotConnectivitySurfacesAsUncertain() async throws {
        for firstError in [Failure.unknown, MockHwFunding.TestError()] as [Error] {
            let funding = MockHwFunding()
            let service = HwRetainedSendService.inMemory()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
            var outcomes: [PrivatePaymentListSendOutcome] = []
            funding.broadcastErrors = [firstError, firstError]

            for _ in 0 ..< 2 {
                await assertThrowsAsync {
                    _ = try await coordinator.signAndBroadcast(
                        manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                        afterFailure: { outcomes.append($0) }
                    )
                } _: { error in
                    XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
                }
            }

            XCTAssertEqual(outcomes, [.uncertain, .uncertain])
            let record = try await service.record(walletId: "jade:wallet")
            XCTAssertNotNil(record)
        }
    }

    func testOrdinaryRefusalAndConnectivityFailuresKeepTheirOwnErrors() async {
        let task = BroadcastError.TaskError(errorDetails: "task")
        let offline = BroadcastError.ElectrumError(errorDetails: "offline")
        let cases: [(first: Error, second: Error?)] = [
            (Failure.refused, nil), // First attempt refusal.
            (Failure.connect, nil), // First attempt connect failure.
            (task, nil), (offline, nil), // Kept, connectivity.
            (Failure.unknown, Failure.connect), // Retry connect failure.
            (Failure.unknown, task),
        ]
        for (first, second) in cases {
            let funding = MockHwFunding()
            let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
            funding.broadcastErrors = second.map { [first, $0] } ?? [first]
            if second != nil {
                await failSend(coordinator)
            }

            let expected = second ?? first
            await assertThrowsAsync {
                try await self.send(coordinator)
            } _: { error in
                XCTAssertEqual("\(error)", "\(expected)")
            }
        }
    }

    func testCancelledOrdinaryBroadcastStaysACancellation() async {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = CancellationError()

        await assertThrowsAsync {
            try await self.send(coordinator)
        } _: { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testShopBroadcastFailureKeepsItsRawError() async {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = Failure.unknown

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                paymentRequestId: .init(paymentRequestId: "original", counterparty: "merchant")
            )
        } _: { error in
            XCTAssertEqual("\(error)", "\(Failure.unknown)")
        }
    }

    func testPreviewOfADifferentPaymentKeepsAttemptedBytes() async throws {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil

        _ = try await coordinator.preparePreview(
            manager: HwWalletManager(), address: "bc1qother", sats: 50000, satsPerVByte: 9, hasIncomingRequest: false
        )

        XCTAssertTrue(coordinator.hasPendingBroadcast)
        await assertThrowsAsync { try await self.send(coordinator, address: "bc1qother", sats: 50000) } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        try await send(coordinator)
        assertSingleSignature(funding, broadcasts: 2)
    }

    func testSwitchingWalletsAwayAndBackRebroadcastsOriginalBytes() async throws {
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = Failure.unknown
        await failSend(coordinator)
        funding.broadcastError = nil

        coordinator.selectWallet("trezor:wallet")
        try await send(coordinator, address: "bc1qother", sats: 50000)
        XCTAssertEqual(funding.signCalls, 2, "The other wallet must not inherit the retained bytes")
        coordinator.completeBroadcast()

        coordinator.selectWallet("jade:wallet")
        try await send(coordinator)

        XCTAssertEqual(funding.signCalls, 2, "The original wallet's durable record must survive the switch")
        XCTAssertEqual(funding.broadcastTransactions.count, 3)
    }

    func testShopSendKeepsItsClosuresAndNeverUsesTheRetainedSendRecord() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original", counterparty: "merchant")
        var retained: [HwFundingSignedTx] = []
        funding.broadcastError = Failure.unknown

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: HwWalletManager(), address: "bc1qtest", sats: 42000, satsPerVByte: 2, paymentRequestId: requestId,
                retainSignedPayment: { retained.append($0) }
            )
        }

        XCTAssertEqual(retained, [funding.signedTx])
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertNil(record)
        XCTAssertTrue(coordinator.isBroadcastUnresolved)
        await assertThrowsAsync {
            try await self.send(coordinator, address: "bc1qother")
        } _: { error in
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }
    }

    func testShopSendIgnoresARetainedOrdinarySend() async throws {
        let funding = MockHwFunding()
        let service = HwRetainedSendService.inMemory()
        funding.broadcastError = Failure.unknown
        await failSend(makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service))
        funding.broadcastError = nil

        let shop = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting(), retainedSends: service)
        _ = try await shop.signAndBroadcast(
            manager: HwWalletManager(), address: "bc1qshop", sats: 50000, satsPerVByte: 2,
            paymentRequestId: .init(paymentRequestId: "original", counterparty: "merchant")
        )

        XCTAssertEqual(funding.signCalls, 2)
        let record = try await service.record(walletId: "jade:wallet")
        XCTAssertEqual(record?.address, "bc1qtest")
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
                    _ = try await retry.preparePreview(
                        manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 3, hasIncomingRequest: true
                    )
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
            let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original", counterparty: "merchant")
            let send = {
                try await coordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    paymentRequestId: requestId,
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
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original", counterparty: "merchant")
        let first = Task {
            try await proofService.withHardwarePaymentOwnership(walletId: "jade:wallet") {
                try await firstCoordinator.signAndBroadcast(
                    manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                    paymentRequestId: requestId,
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
                    paymentRequestId: requestId,
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
        connecting: MockHwConnecting,
        retainedSends: HwRetainedSendService = .inMemory(),
        broadcastTimeout: Double = 5
    ) -> HwSendCoordinator {
        HwSendCoordinator(
            walletId: walletId,
            signerFactory: { [self] _, address, satsPerVByte in
                makeSigner(
                    funding: funding,
                    connecting: connecting,
                    feeRate: satsPerVByte,
                    address: address,
                    timeouts: (compose: 5, sign: 5, broadcast: broadcastTimeout)
                )
            },
            retainedSends: retainedSends
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

    func testBroadcastTimeoutThrowsBroadcastUncertainWithoutClearingSession() async {
        let funding = MockHwFunding()
        funding.broadcastDelay = 0.4
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (compose: 5, sign: 5, broadcast: 0.05))

        await assertThrowsAsync {
            _ = try await signer.broadcastSignedFunding(funding.signedTx)
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .broadcastUncertain)
        }
        XCTAssertEqual(funding.signCalls, 0, "retrying broadcast does not require signing")
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "a broadcast timeout must not tear down the device session")
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
