@testable import Bitkit
import BitkitCore
import XCTest

/// Coordination coverage for the hardware-wallet transfer path in `TransferViewModel`: it drives the
/// `HwFundingSigner` (built from the injected capabilities), maps signer failures to published state,
/// and guards against re-entry. The device orchestration itself is covered by `HwFundingSignerTests`.
@MainActor
final class TransferViewModelHwTests: XCTestCase {
    private func makeViewModel(
        funding: MockHwFunding,
        connecting: MockHwConnecting,
        feeRate: UInt64? = 2,
        timeouts: (reconnect: Double, compose: Double, sign: Double, broadcast: Double) = (reconnect: 5, compose: 5, sign: 5, broadcast: 5)
    ) -> TransferViewModel {
        TransferViewModel(
            hwFunding: funding,
            hwConnecting: connecting,
            hwFeeRateProvider: { feeRate },
            hwTimeouts: timeouts
        )
    }

    private func awaitSigningComplete(_ vm: TransferViewModel, timeout: Double = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.hwSpending.isSigning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testConfirmWithoutHwCapabilitiesSurfacesGenericError() {
        let vm = TransferViewModel() // no signer injected
        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error") }
        XCTAssertFalse(vm.hwSpending.isSigning)
    }

    func testUpdateHwLimitsSurfacesErrorWhenAvailabilityFails() async {
        let funding = MockHwFunding()
        funding.accountError = MockHwFunding.TestError()
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())

        await vm.updateHwLimits(deviceId: "dev1", blocktankInfo: nil, estimateOrderFee: { _, _ in (0, 0) })

        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error") }
        XCTAssertFalse(vm.hwSpending.isLoading)
    }

    func testUpdateHwLimitsClearsStalePreviousDeviceCap() async {
        let funding = MockHwFunding()
        funding.accountError = MockHwFunding.TestError()
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())
        vm.hwSpending.maxAllowedToSend = 999_999 // stale cap from a previously-selected device

        await vm.updateHwLimits(deviceId: "dev1", blocktankInfo: nil, estimateOrderFee: { _, _ in (0, 0) })

        XCTAssertEqual(vm.hwSpending.maxAllowedToSend, 0, "a reload must not keep the previous device's cap")
    }

    func testReconnectFailureMapsToReconnectErrorAndResetsSigning() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = MockHwFunding.TestError()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .reconnect(isBluetooth: false))
        XCTAssertFalse(vm.hwSpending.isSigning)
    }

    func testReconnectFailureCarriesBluetoothFlagForKnownBleDevice() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = MockHwFunding.TestError()
        connecting.isBluetooth = true
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .reconnect(isBluetooth: true), "a known BLE device gets the softer INFO reconnect toast")
    }

    func testRawSignErrorMapsToGenericError() async {
        let funding = MockHwFunding()
        funding.signError = MockHwFunding.TestError()
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error, got \(String(describing: vm.hwTransferError))") }
        XCTAssertTrue(connecting.staleDisconnects.isEmpty)
    }

    func testBroadcastFailureRetainsSignedTransactionForRetry() async {
        let funding = MockHwFunding()
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "offline")
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)
        let order = IBtOrder.mock()

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertTrue(vm.hwSpending.hasPendingBroadcast)
        XCTAssertEqual(vm.hwSpending.miningFeeSats, funding.funding.miningFeeSats)
        XCTAssertEqual(funding.signCalls, 1)
        XCTAssertEqual(funding.broadcastCalls, 1)
        XCTAssertEqual(vm.hwTransferError, .broadcastConnectivity)

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertTrue(vm.hwSpending.hasPendingBroadcast)
        XCTAssertEqual(connecting.ensureCalls, 1)
        XCTAssertEqual(funding.composeCalls.count, 1)
        XCTAssertEqual(funding.signCalls, 1, "retry must reuse the signed transaction")
        XCTAssertEqual(funding.broadcastCalls, 2)

        vm.cancelHwSigning()
        XCTAssertTrue(vm.hwSpending.hasPendingBroadcast, "leaving must retain an uncertain signed transaction")
        vm.onOrderCreated(order: .mock())
        XCTAssertFalse(vm.hwSpending.hasPendingBroadcast, "starting a new order discards the previous retry state")
    }

    func testBroadcastRetryDoesNotReuseSignedTransactionAfterOrderAddressChanges() async {
        let funding = MockHwFunding()
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "offline")
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())
        var order = IBtOrder.mock()

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)

        order.payment?.onchain?.address = "bc1qnewdestination"
        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(funding.signCalls, 2)
        XCTAssertEqual(funding.composeCalls.last?.address, "bc1qnewdestination")
    }

    func testDeviceCancelDuringSigningIsSilent() async {
        let funding = MockHwFunding()
        funding.signError = TrezorError.UserCancelled
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertNil(vm.hwTransferError, "a device cancel must not surface a toast")
        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertEqual(vm.hwSignedEvent, 0, "a cancelled transfer must not advance the flow")
        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "a device cancel must not tear down the session")
    }

    /// On device, `ServiceQueue` boxes the `TrezorError` into an `AppError` before it reaches the view
    /// model, so the silent-cancel path must survive the wrapping (raw `TrezorError` is covered above).
    /// `AppError` is qualified as `Bitkit.AppError` because `Errors.swift` is also compiled into this
    /// test target — an unqualified `AppError` would be the test-target copy, not what production throws.
    func testWrappedDeviceCancelDuringSigningIsSilent() async {
        let funding = MockHwFunding()
        funding.signError = Bitkit.AppError(error: TrezorError.UserCancelled)
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertNil(vm.hwTransferError, "a wrapped device cancel must not surface a toast")
        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertEqual(vm.hwSignedEvent, 0, "a cancelled transfer must not advance the flow")
    }

    func testDeviceCancelDuringReconnectIsSilent() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = TrezorError.UserCancelled
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertNil(vm.hwTransferError, "a reconnect-step cancel must not surface a toast")
        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertTrue(funding.composeCalls.isEmpty, "compose must not run after a reconnect cancel")
    }

    func testWarmUpHardwareConnectionDelegatesToConnecting() {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.warmUpHardwareConnection(deviceId: "dev1")

        XCTAssertEqual(connecting.warmUpCalls, ["dev1"])
    }

    func testCancelHwSigningStopsInFlightSign() async {
        let funding = MockHwFunding()
        funding.signDelay = 1.0 // keep signing in-flight so cancel interrupts it
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        while !vm.hwSpending.isSigning {
            await Task.yield()
        }
        vm.cancelHwSigning()
        for _ in 0 ..< 50 where connecting.staleDisconnects.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await awaitSigningComplete(vm)

        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertEqual(vm.hwSignedEvent, 0, "a cancelled sign must not advance the flow")
        XCTAssertEqual(connecting.staleDisconnects, ["dev1"], "cancelling during sign must tear down the stale session")
    }

    func testDeviceBusyMapsToDeviceBusyError() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = TrezorError.DeviceBusy
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .deviceBusy)
    }

    func testFirmwareErrorMapsToFirmwareReconnectError() async {
        let funding = MockHwFunding()
        funding.signError = Bitkit.AppError(
            message: "Firmware error",
            debugMessage: "Device error (code 99): Firmware error"
        )
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .firmwareReconnect)
    }

    func testElectrumBroadcastFailureKeepsPendingAndSurfacesConnectivityToast() async {
        let funding = MockHwFunding()
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "offline")
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())
        let order = IBtOrder.mock()

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertTrue(vm.hwSpending.hasPendingBroadcast)
        XCTAssertEqual(vm.hwTransferError, .broadcastConnectivity)
    }

    func testPermanentBroadcastFailureClearsPendingState() async {
        let funding = MockHwFunding()
        funding.broadcastError = Bitkit.AppError(message: "rejected", debugMessage: "invalid tx")
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertFalse(vm.hwSpending.hasPendingBroadcast)
        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error") }
    }

    func testElectrumBroadcastRejectionClearsPendingState() async {
        let funding = MockHwFunding()
        funding.broadcastError = BroadcastError.ElectrumError(
            errorDetails: "Broadcast failed: bad-txns-inputs-missingorspent"
        )
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertFalse(vm.hwSpending.hasPendingBroadcast)
        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error") }
        XCTAssertEqual(funding.signCalls, 1)
    }

    func testUpdateHwLimitsClearsDesyncedPendingBroadcast() async {
        let funding = MockHwFunding()
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())
        funding.broadcastError = BroadcastError.ElectrumError(errorDetails: "offline")
        let order = IBtOrder.mock()

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)
        XCTAssertTrue(vm.hwSpending.hasPendingBroadcast)

        await vm.updateHwLimits(deviceId: "dev1", blocktankInfo: nil, estimateOrderFee: { _, _ in (0, 0) })

        XCTAssertFalse(vm.hwSpending.hasPendingBroadcast)
        vm.cancelHwSigning()
        XCTAssertEqual(funding.signCalls, 1, "cancel after limits reload must not be blocked by stale pending tx")
    }

    func testUpdateHwFundingFeeEstimateSetsMiningFeeBeforeSigning() async {
        let funding = MockHwFunding()
        let vm = makeViewModel(funding: funding, connecting: MockHwConnecting())
        let order = IBtOrder.mock()

        await vm.updateHwFundingFeeEstimate(order: order, deviceId: "dev1")

        XCTAssertEqual(vm.hwSpending.miningFeeSats, funding.funding.miningFeeSats)
        XCTAssertEqual(funding.estimateCalls.count, 1)
        XCTAssertTrue(funding.composeCalls.isEmpty)
    }

    func testReentrancyGuardIgnoresConcurrentConfirm() async {
        let funding = MockHwFunding()
        funding.composeError = MockHwFunding.TestError() // fail before the network-bound funding tail
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        // Second call while the first is still signing must be ignored.
        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(connecting.ensureCalls, 1, "only the first confirm should run")
        XCTAssertEqual(funding.composeCalls.count, 1)
    }

    func testMissingOrderAddressSurfacesGenericErrorWithoutSigning() {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)
        var order = IBtOrder.mock()
        order.payment?.onchain?.address = ""

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")

        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error") }
        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertEqual(connecting.ensureCalls, 0)
    }
}
