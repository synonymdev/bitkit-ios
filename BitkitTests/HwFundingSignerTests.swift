@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

/// Device-signing orchestration coverage for `HwFundingSigner`, exercised in isolation from
/// `TransferViewModel` via the `HwTransferFunding` / `HwTransferConnecting` mocks.
@MainActor
final class HwFundingSignerTests: XCTestCase {
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
            let coordinator = HwSendCoordinator(walletId: "trezor:original-ios-wallet", signerFactory: { [self] _, address, rate in
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
            let coordinator = HwSendCoordinator(
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

    func testCoordinatorDeniedFirstAttemptDropsPreparedPayment() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = HwSendCoordinator(
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
        let coordinator = HwSendCoordinator(
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
            let coordinator = HwSendCoordinator(
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
                let coordinator = HwSendCoordinator(
                    walletId: "trezor:wallet",
                    signerFactory: { [self] _, address, satsPerVByte in
                        makeSigner(funding: funding, connecting: MockHwConnecting(), feeRate: satsPerVByte, address: address)
                    }
                )
                if hadPriorAttempt {
                    funding.broadcastError = HwTransferError.broadcastUncertain
                    await assertThrowsAsync {
                        _ = try await coordinator.signAndBroadcast(manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2)
                    }
                    funding.broadcastError = nil
                }
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
                XCTAssertEqual(coordinator.isBroadcastUnresolved, hadPriorAttempt)
            }
        }
    }

    func testHardwareSubmissionRejectsExpiredDeadlineBeforeCallingElectrum() async throws {
        do {
            _ = try await OnChainHwService.shared.broadcastRawTx(
                serializedTx: "invalid", electrumUrl: "invalid",
                paymentDeadline: PaykitPreciseInstant(date: Date().addingTimeInterval(-1))
            )
            XCTFail("Expired payment must not reach Electrum")
        } catch {
            XCTAssertEqual((error as? Bitkit.AppError)?.underlyingError as? PaykitPaymentRequestError, .requestExpired)
        }
    }

    func testCoordinatorBroadcastFailureRemainsUncertainAfterPendingPaymentIsCleared() async {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = HwSendCoordinator(
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
        let coordinator = HwSendCoordinator(
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
        let coordinator = HwSendCoordinator(
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
        let funding = MockHwFunding()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let manager = HwWalletManager()
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "original-request", counterparty: "original-merchant")
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "offline")
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
        XCTAssertNil(coordinator.resolveObservedShopPayment(original, paymentIdentity: identity, currentIdentity: "pubky" + String(repeating: "x", count: 52)))
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

    func testCancelledAuthorizationCannotBroadcastOrResetANewerAttempt() async throws {
        let funding = MockHwFunding()
        let manager = HwWalletManager()
        let coordinator = makeCoordinator(walletId: "jade:wallet", funding: funding, connecting: MockHwConnecting())
        let suspended = AsyncGate()
        let nextPreparation = AsyncGate()
        var suspensionStarted = false
        var nextStarted = false
        var retained = 0
        var cleared = 0
        var staleFailures = 0
        let first = Task {
            try await coordinator.signAndBroadcast(
                manager: manager, address: "bc1qtest", sats: 42000, satsPerVByte: 2,
                beforeBroadcastAttempt: {
                    suspensionStarted = true
                    await suspended.wait()
                },
                retainSignedPayment: { _ in
                    retained += 1
                },
                clearSignedPaymentBeforeDispatch: { _ in
                    cleared += 1
                    return true
                },
                afterFailure: { _ in staleFailures += 1 }
            )
        }
        await waitUntil { suspensionStarted }
        XCTAssertTrue(suspensionStarted)
        coordinator.cancel()
        let second = Task {
            try await self.signAndBroadcast(coordinator, manager: manager) { _ in
                nextStarted = true
                await nextPreparation.wait()
            }
        }
        await waitUntil { nextStarted }
        XCTAssertTrue(nextStarted)
        suspended.open()
        await assertThrowsAsync {
            _ = try await first.value
        } _: { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(funding.broadcastCalls, 0, "the abandoned payment must never submit")
        XCTAssertEqual(retained, 0)
        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(staleFailures, 0, "the old callback must not cancel the new payment")
        XCTAssertTrue(coordinator.isSigning)
        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertFalse(coordinator.isBroadcastUnresolved)
        nextPreparation.open()
        _ = try await second.value
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
                        if cleanupSucceeds { receipt = nil }
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
        HwSendCoordinator(
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

    func testHappyPathComposesFinalOrderFeeAndReturnsBroadcast() async throws {
        let funding = MockHwFunding()
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting())
        let order = IBtOrder.mock() // feeSat = 1000, address = "bc1q..."
        var composedMiningFee: UInt64?

        let signed = try await signer.prepareSignedFunding(
            order: order,
            walletId: "trezor:wallet",
            address: XCTUnwrap(order.payment?.onchain?.address),
            onComposed: { composedMiningFee = $0.miningFeeSats }
        )
        let result = try await signer.broadcastSignedFunding(signed)

        XCTAssertEqual(result.txId, "txid")
        XCTAssertEqual(composedMiningFee, funding.funding.miningFeeSats)
        XCTAssertEqual(funding.composeCalls.count, 1)
        XCTAssertEqual(funding.composeCalls.first?.sats, order.feeSat)
        XCTAssertEqual(funding.composeCalls.first?.address, order.payment?.onchain?.address)
        XCTAssertEqual(funding.composeCalls.first?.satsPerVByte, 2)
    }

    func testReconnectFailureThrowsReconnectAndSkipsCompose() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = MockHwFunding.TestError()
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .reconnect(isBluetooth: false))
        }
        XCTAssertTrue(funding.composeCalls.isEmpty)
        XCTAssertEqual(funding.signCalls, 0)
    }

    /// The reconnect deadline belongs to the wallet's device: a Jade may be waiting for its PIN.
    func testReconnectUsesTheWalletsTimeout() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectDelay = 0.4
        connecting.reconnectTimeoutSeconds = 0.05
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .reconnect(isBluetooth: false))
        }
        XCTAssertEqual(connecting.staleDisconnects, ["jade:wallet"], "the timed-out session is cleaned up")
        XCTAssertTrue(funding.composeCalls.isEmpty)
    }

    func testComposeFailureThrowsFundingError() async {
        let funding = MockHwFunding()
        funding.composeError = MockHwFunding.TestError()
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting())

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            if case .funding = error as? HwTransferError {} else {
                XCTFail("expected .funding, got \(error)")
            }
        }
        XCTAssertEqual(funding.signCalls, 0)
    }

    func testSigningTimeoutThrowsTimeoutAndClearsStaleSession() async {
        let funding = MockHwFunding()
        funding.signDelay = 0.4
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (compose: 5, sign: 0.05, broadcast: 5))

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .signingTimeout)
        }
        await Task.yield()
        XCTAssertEqual(connecting.staleDisconnects, ["trezor:wallet"])
        XCTAssertEqual(funding.signCalls, 1)
    }

    func testSigningTimeoutDoesNotWaitForCancellationIgnoringOperation() async {
        let funding = MockHwFunding()
        funding.cancellationIgnoringSignDelay = 0.5
        let connecting = MockHwConnecting()
        let signer = makeSigner(
            funding: funding,
            connecting: connecting,
            timeouts: (compose: 5, sign: 0.05, broadcast: 5)
        )
        let start = ContinuousClock.now

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .signingTimeout)
        }

        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
        await Task.yield()
        XCTAssertEqual(connecting.staleDisconnects, ["trezor:wallet"])
    }

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

    func testComposeTimeoutClearsStaleSessionAndThrowsTimeout() async {
        let funding = MockHwFunding()
        funding.composeDelay = 0.4
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (compose: 0.05, sign: 5, broadcast: 5))

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .signingTimeout)
        }
        await Task.yield()
        XCTAssertEqual(connecting.staleDisconnects, ["trezor:wallet"], "a compose timeout must tear down the stale session")
        XCTAssertEqual(funding.signCalls, 0, "signing must not run after a compose timeout")
    }

    func testRawSignErrorPropagatesUnwrapped() async {
        let funding = MockHwFunding()
        funding.signError = MockHwFunding.TestError()
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertTrue(error is MockHwFunding.TestError, "a real signing error must propagate unwrapped")
            XCTAssertNil(error as? HwTransferError)
        }
        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "a non-timeout error must not clear the session")
    }

    func testBrokenThpSessionReconnectsAndRetriesSigningOnce() async throws {
        let funding = MockHwFunding()
        funding.signErrors = [
            Bitkit.AppError(error: TrezorError.ProtocolError(errorDetails: "THP decryption error: aead::Error")),
        ]
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting)

        let result = try await signer.prepareSignedFunding(
            order: .mock(),
            walletId: "trezor:wallet",
            address: "bc1q..."
        )

        XCTAssertEqual(result, funding.signedTx)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(connecting.staleDisconnects, ["trezor:wallet"])
        XCTAssertEqual(connecting.ensureCalls, 2)
    }

    // MARK: - Vendor errors

    func testBusyJadeReportsJadeVendor() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = Bitkit.AppError(error: JadeError.DeviceLocked)
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .deviceBusy(.blockstream))
        }
        XCTAssertTrue(funding.composeCalls.isEmpty)
    }

    func testADeviceHoldingAnotherWalletReportsTheWalletMismatch() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = HwWalletMismatchError()
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .walletMismatch)
        }
        XCTAssertTrue(funding.composeCalls.isEmpty)
    }

    func testBusyTrezorReportsTrezorVendor() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = Bitkit.AppError(error: TrezorError.DeviceBusy)
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .deviceBusy(.trezor))
        }
        XCTAssertTrue(funding.composeCalls.isEmpty)
    }

    func testJadeWrongPinDuringReconnectShowsJadeCopy() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.isBluetooth = true
        let signer = makeSigner(funding: funding, connecting: connecting)

        for (error, key) in [
            (JadeError.InvalidPin, "hardware__jade_invalid_pin"),
            (JadeError.PinServerError(errorDetails: "unreachable"), "hardware__jade_pinserver_error"),
        ] {
            connecting.connectError = Bitkit.AppError(error: error)
            await assertThrowsAsync {
                _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
            } _: { thrown in
                XCTAssertEqual(thrown as? HwTransferError, .generic(t(key)), "\(error)")
            }
        }
        XCTAssertTrue(funding.composeCalls.isEmpty)
    }

    func testAJadeLinkFailureDuringReconnectStillReportsAReconnect() async {
        let connecting = MockHwConnecting()
        connecting.connectError = Bitkit.AppError(error: JadeError.DeviceDisconnected)
        connecting.isBluetooth = true
        let signer = makeSigner(funding: MockHwFunding(), connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .reconnect(isBluetooth: true))
        }
    }

    func testAJadeComposeFailureKeepsTheJadeCopy() async {
        let funding = MockHwFunding()
        funding.composeError = Bitkit.AppError(error: JadeError.InvalidPin)
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting())

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .generic(t("hardware__jade_invalid_pin")))
        }

        funding.composeError = Bitkit.AppError(error: JadeError.DeviceBusy)
        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .deviceBusy(.blockstream))
        }

        funding.composeError = Bitkit.AppError(error: JadeError.Timeout)
        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? HwTransferError, .funding(t("hardware__connect_error")))
        }
        XCTAssertEqual(funding.signCalls, 0)
    }

    func testAJadeSessionFailureRetriesSigningOnce() async throws {
        let funding = MockHwFunding()
        funding.signErrors = [Bitkit.AppError(error: JadeError.DeviceDisconnected)]
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting)

        let result = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")

        XCTAssertEqual(result, funding.signedTx)
        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(connecting.staleDisconnects, ["jade:wallet"])
        XCTAssertEqual(connecting.ensureCalls, 2)
    }

    func testAJadeCancellationOnDeviceIsRethrown() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = JadeError.UserCancelled
        let signer = makeSigner(funding: funding, connecting: connecting)

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertEqual(error as? JadeError, .UserCancelled, "a cancel on the Jade must not become a reconnect failure")
        }
        XCTAssertTrue(funding.composeCalls.isEmpty)

        connecting.connectError = nil
        funding.signError = Bitkit.AppError(error: JadeError.UserCancelled)
        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "jade:wallet", address: "bc1q...")
        } _: { error in
            XCTAssertTrue(error.isJadeUserCancellation())
            XCTAssertNil(error as? HwTransferError)
        }
        XCTAssertEqual(funding.signCalls, 1, "a cancel on the Jade is not retried")
        XCTAssertTrue(connecting.staleDisconnects.isEmpty)
    }
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
