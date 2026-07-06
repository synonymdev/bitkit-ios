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

    func testReconnectFailureMapsToReconnectErrorAndResetsSigning() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = MockHwFunding.TestError()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .reconnect)
        XCTAssertFalse(vm.hwSpending.isSigning)
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
