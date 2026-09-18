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

    func testCoordinatorRetryReusesSignedPaymentAfterConnectivityFailure() async throws {
        try await assertCoordinatorRetryReusesSignedPayment(
            error: BroadcastError.ElectrumError(errorDetails: "offline")
        )
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
        var completedTransactionIds: [String] = []
        funding.broadcastError = error

        await assertThrowsAsync {
            _ = try await coordinator.signAndBroadcast(
                manager: manager,
                address: "bc1qtest",
                sats: 42000,
                satsPerVByte: 2,
                beforeBroadcast: { beforeBroadcastCalls += 1 },
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
            beforeBroadcast: { beforeBroadcastCalls += 1 },
            afterBroadcast: { completedTransactionIds.append($0.txId) }
        )

        XCTAssertEqual(funding.composeCalls.count, 1)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 2)
        XCTAssertEqual(funding.broadcastTransactions, [funding.signedTx.serializedTx, funding.signedTx.serializedTx])
        XCTAssertEqual(beforeBroadcastCalls, 1)
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
            try await self.signAndBroadcast(coordinator, manager: manager) {
                preparations.record("first")
                await firstPreparation.wait()
            }
        }
        await waitUntil { preparations.contains("first") }
        coordinator.cancel()

        let second = Task {
            try await self.signAndBroadcast(coordinator, manager: manager) {
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

    func testCoordinatorCanBeLeftWhileTheDeviceReconnectsBeforeASignRetry() async throws {
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
        beforeBroadcast: @escaping () async throws -> Void = {}
    ) async throws -> HwFundingBroadcastResult {
        try await coordinator.signAndBroadcast(
            manager: manager,
            address: "bc1qtest",
            sats: 42000,
            satsPerVByte: 2,
            beforeBroadcast: beforeBroadcast
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
