@testable import Bitkit
import BitkitCore
import XCTest

/// Device-signing orchestration coverage for `HwFundingSigner`, exercised in isolation from
/// `TransferViewModel` via the `HwTransferFunding` / `HwTransferConnecting` mocks.
@MainActor
final class HwFundingSignerTests: XCTestCase {
    private func makeSigner(
        funding: MockHwFunding,
        connecting: MockHwConnecting,
        feeRate: UInt64? = 2,
        address: String? = "bc1qtest",
        timeouts: (reconnect: Double, compose: Double, sign: Double, broadcast: Double) = (reconnect: 5, compose: 5, sign: 5, broadcast: 5)
    ) -> HwFundingSigner {
        HwFundingSigner(
            funding: funding,
            connecting: connecting,
            feeRateProvider: { feeRate },
            addressProvider: { if let address { return address } else { throw MockHwFunding.TestError() } },
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

    func testCoordinatorRetryReusesSignedPaymentAfterConnectivityFailure() async throws {
        try await assertCoordinatorRetryReusesSignedPayment(
            error: BroadcastError.ElectrumError(errorDetails: "offline")
        )
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
        var beforeBroadcastCalls = 0
        funding.broadcastError = error

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeBroadcast: { beforeBroadcastCalls += 1 }
            )
        }

        XCTAssertTrue(coordinator.hasPendingBroadcast)
        XCTAssertTrue(coordinator.isBroadcastUnresolved)

        funding.broadcastError = nil
        _ = try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            beforeBroadcast: { beforeBroadcastCalls += 1 }
        )

        XCTAssertEqual(funding.composeCalls.count, 1)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
        XCTAssertEqual(beforeBroadcastCalls, 1)
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

    func testComposeFailureThrowsFundingError() async {
        let funding = MockHwFunding()
        funding.composeError = MockHwFunding.TestError()
        let signer = makeSigner(funding: funding, connecting: MockHwConnecting())

        await assertThrowsAsync {
            _ = try await signer.prepareSignedFunding(order: .mock(), walletId: "trezor:wallet", address: "bc1q...")
        } _: { error in
            if case .funding = error as? HwTransferError {} else { XCTFail("expected .funding, got \(error)") }
        }
        XCTAssertEqual(funding.signCalls, 0)
    }

    func testSigningTimeoutThrowsTimeoutAndClearsStaleSession() async {
        let funding = MockHwFunding()
        funding.signDelay = 0.4
        let connecting = MockHwConnecting()
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (reconnect: 5, compose: 5, sign: 0.05, broadcast: 5))

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
            timeouts: (reconnect: 5, compose: 5, sign: 0.05, broadcast: 5)
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
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (reconnect: 5, compose: 5, sign: 5, broadcast: 0.05))

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
        let signer = makeSigner(funding: funding, connecting: connecting, timeouts: (reconnect: 5, compose: 0.05, sign: 5, broadcast: 5))

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
