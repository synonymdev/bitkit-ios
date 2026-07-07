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
        await awaitSigningComplete(vm)

        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertEqual(vm.hwSignedEvent, 0, "a cancelled sign must not advance the flow")
        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "cancelling must not tear down the session")
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
