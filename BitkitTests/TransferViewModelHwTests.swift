@testable import Bitkit
import BitkitCore
import XCTest

/// Hardware-wallet transfer-to-spending coverage for `TransferViewModel`, adapting the HW cases in
/// bitkit-android's `TransferViewModelTest`: fee-reserve math, on-device sign orchestration, and the
/// reconnect / signing-timeout / compose-error state handling. The funding and device-session
/// capabilities are injected as mocks via the `HwTransferFunding` / `HwTransferConnecting` seams.
@MainActor
final class TransferViewModelHwTests: XCTestCase {
    private struct TestError: Error {}

    // MARK: - Mocks

    private final class MockHwFunding: HwTransferFunding {
        var account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
        var accountError: Error?
        var composeError: Error?
        var signError: Error?
        var signDelay: Double = 0
        var funding = HwFundingTransaction(psbt: "psbt", miningFeeSats: 141, feeRate: 1, totalSpent: 43186, satsPerVByte: 1)
        var broadcast = HwFundingBroadcastResult(txId: "txid", miningFeeSats: 141, feeRate: 1, totalSpent: 43186)

        private(set) var composeCalls: [(address: String, sats: UInt64, satsPerVByte: UInt64)] = []
        private(set) var signCalls = 0

        func getFundingAccount(deviceId _: String, addressType _: AddressScriptType) throws -> HwFundingAccount {
            if let accountError { throw accountError }
            return account
        }

        func composeFundingTransaction(
            deviceId _: String,
            address: String,
            sats: UInt64,
            satsPerVByte: UInt64,
            addressType _: AddressScriptType
        ) async throws -> HwFundingTransaction {
            composeCalls.append((address, sats, satsPerVByte))
            if let composeError { throw composeError }
            return funding
        }

        func signAndBroadcastFunding(deviceId _: String, funding _: HwFundingTransaction) async throws -> HwFundingBroadcastResult {
            signCalls += 1
            if signDelay > 0 { try await Task.sleep(nanoseconds: UInt64(signDelay * 1_000_000_000)) }
            if let signError { throw signError }
            return broadcast
        }
    }

    private final class MockHwConnecting: HwTransferConnecting {
        var connectError: Error?
        private(set) var ensureCalls = 0
        private(set) var staleDisconnects: [String] = []

        func ensureConnected(deviceId _: String) async throws {
            ensureCalls += 1
            if let connectError { throw connectError }
        }

        func disconnectStaleSession(deviceId: String) async {
            staleDisconnects.append(deviceId)
        }
    }

    // MARK: - Helpers

    private func makeViewModel(
        funding: MockHwFunding,
        connecting: MockHwConnecting,
        feeRate: UInt64? = 2,
        timeouts: (reconnect: Double, compose: Double, sign: Double) = (reconnect: 5, compose: 5, sign: 5)
    ) -> TransferViewModel {
        TransferViewModel(
            transferService: TransferService(lightningService: .shared, blocktankService: CoreService.shared.blocktank),
            sheetViewModel: SheetViewModel(),
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

    // MARK: - Fee reserve

    func testFeeReserveUsesRateWhenAvailable() {
        let reserve = TransferViewModel.hwFundingFeeReserve(balanceSats: 1_000_000, satsPerVByte: 5)
        XCTAssertEqual(reserve, 5 * 1200)
    }

    func testFeeReserveFallbackUsesPercentWhenLarger() {
        // 10% of 1,000,000 = 100,000 dominates the 1,200 sat floor.
        let reserve = TransferViewModel.hwFundingFeeReserve(balanceSats: 1_000_000, satsPerVByte: nil)
        XCTAssertEqual(reserve, 100_000)
    }

    func testFeeReserveFallbackUsesFloorWhenPercentSmaller() {
        // 10% of 5,000 = 500, below the 1 * 1200 floor.
        let reserve = TransferViewModel.hwFundingFeeReserve(balanceSats: 5000, satsPerVByte: nil)
        XCTAssertEqual(reserve, 1200)
    }

    // MARK: - Sign orchestration

    func testReconnectFailureSurfacesReconnectError() async {
        let funding = MockHwFunding()
        let connecting = MockHwConnecting()
        connecting.connectError = TestError()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .reconnect)
        XCTAssertFalse(vm.hwSpending.isSigning)
        XCTAssertTrue(funding.composeCalls.isEmpty, "compose must not run when reconnect fails")
        XCTAssertEqual(funding.signCalls, 0)
    }

    func testComposeFundsFinalOrderFeeAndSurfacesFundingErrorOnFailure() async {
        let funding = MockHwFunding()
        funding.composeError = TestError()
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)
        let order = IBtOrder.mock() // feeSat = 1000, onchain address = "bc1q..."

        vm.onTransferToSpendingHwConfirm(order: order, deviceId: "dev1")
        await awaitSigningComplete(vm)

        // The signed funding output equals the final order.feeSat, sent to the order's address.
        XCTAssertEqual(funding.composeCalls.count, 1)
        XCTAssertEqual(funding.composeCalls.first?.sats, order.feeSat)
        XCTAssertEqual(funding.composeCalls.first?.address, order.payment?.onchain?.address)
        XCTAssertEqual(funding.composeCalls.first?.satsPerVByte, 2)
        XCTAssertEqual(funding.signCalls, 0)
        if case .funding = vm.hwTransferError {} else { XCTFail("expected .funding error, got \(String(describing: vm.hwTransferError))") }
    }

    func testSigningTimeoutClearsStaleSession() async {
        let funding = MockHwFunding()
        funding.signDelay = 0.4
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting, timeouts: (reconnect: 5, compose: 5, sign: 0.05))

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(vm.hwTransferError, .signingTimeout)
        XCTAssertEqual(connecting.staleDisconnects, ["dev1"], "a signing timeout must clear the stale session")
        XCTAssertEqual(funding.signCalls, 1)
    }

    func testGenericSignErrorSurfacesGenericError() async {
        let funding = MockHwFunding()
        funding.signError = TestError()
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        if case .generic = vm.hwTransferError {} else { XCTFail("expected .generic error, got \(String(describing: vm.hwTransferError))") }
        XCTAssertTrue(connecting.staleDisconnects.isEmpty, "a non-timeout error must not clear the session")
    }

    func testReentrancyGuardIgnoresConcurrentConfirm() async {
        let funding = MockHwFunding()
        funding.composeError = TestError() // fail before reaching the network-bound funding tail
        let connecting = MockHwConnecting()
        let vm = makeViewModel(funding: funding, connecting: connecting)

        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        // Second call while the first is still signing must be ignored.
        vm.onTransferToSpendingHwConfirm(order: .mock(), deviceId: "dev1")
        await awaitSigningComplete(vm)

        XCTAssertEqual(connecting.ensureCalls, 1, "only the first confirm should run")
        XCTAssertEqual(funding.composeCalls.count, 1)
    }
}
