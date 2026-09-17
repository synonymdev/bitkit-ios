@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

@MainActor
final class BlocktankRefundAddressLiveIntegrationTests: XCTestCase {
    private let walletIndex = 0
    private let lightning = Bitkit.LightningService.shared
    private let core = Bitkit.CoreService.shared

    override func setUp() async throws {
        try await super.setUp()
        try Bitkit.Keychain.wipeEntireKeychain()
        Bitkit.SettingsViewModel.shared.resetToDefaults()
        Bitkit.BlocktankRefundAddressStore().clear()
    }

    override func tearDown() async throws {
        lightning.dumpLdkLogs()
        if lightning.status?.isRunning == true {
            try? await lightning.stop()
        }
        try? await lightning.wipeStorage(walletIndex: walletIndex)
        try Bitkit.Keychain.wipeEntireKeychain()
        Bitkit.SettingsViewModel.shared.resetToDefaults()
        try await super.tearDown()
    }

    func testRefundAddressLifecycleAcrossOrdersRestartAndVssRestore() async throws {
        guard Bitkit.Env.network == .regtest else {
            throw XCTSkip("Blocktank refund address integration requires regtest")
        }

        let settings = Bitkit.SettingsViewModel.shared
        settings.selectedAddressType = .nativeSegwit
        settings.addressTypesToMonitor = [.nativeSegwit]

        let mnemonic = try Bitkit.StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        XCTAssertFalse(mnemonic.isEmpty)
        try await lightning.setup(walletIndex: walletIndex)
        try await lightning.start()
        try await lightning.sync()
        XCTAssertNotNil(lightning.nodeId)

        var submittedOptions: [CreateOrderOptions] = []
        var estimatedOptions: [CreateOrderOptions] = []
        let makeViewModel = {
            let client = Bitkit.BlocktankOrderClient(
                nodeId: { self.lightning.nodeId },
                sign: { try await self.lightning.sign(message: $0) },
                submit: { lspBalanceSat, expiryWeeks, options in
                    submittedOptions.append(options)
                    return try await self.core.blocktank.newOrder(
                        lspBalanceSat: lspBalanceSat,
                        channelExpiryWeeks: expiryWeeks,
                        options: options
                    )
                },
                estimate: { lspBalanceSat, expiryWeeks, options in
                    estimatedOptions.append(options)
                    return try await self.core.blocktank.estimateFee(
                        lspBalanceSat: lspBalanceSat,
                        channelExpiryWeeks: expiryWeeks,
                        options: options
                    )
                }
            )
            return Bitkit.BlocktankViewModel(
                coreService: self.core,
                lightningService: self.lightning,
                orderClient: client,
                startPolling: false
            )
        }

        var viewModel = makeViewModel()
        for _ in 0 ..< 5 {
            _ = try await viewModel.estimateOrderFee(clientBalance: 0, lspBalance: 100_000)
        }
        XCTAssertEqual(estimatedOptions.count, 5)
        XCTAssertTrue(estimatedOptions.allSatisfy { $0.refundOnchainAddress == nil })
        XCTAssertNil(try Bitkit.BlocktankRefundAddressStore().load(), "Fee estimates must not allocate refund addresses")

        let firstOrder = try await viewModel.createOrder(clientBalance: 0, lspBalance: 100_000)
        let firstRefund = try XCTUnwrap(Bitkit.BlocktankRefundAddressStore().load())
        XCTAssertEqual(submittedOptions.last?.refundOnchainAddress, firstRefund.address)
        XCTAssertTrue(firstRefund.address.hasPrefix("bcrt1q"))

        let clientFundedOrder = try await viewModel.createOrder(clientBalance: 25000, lspBalance: 100_000)
        XCTAssertEqual(submittedOptions.last?.refundOnchainAddress, firstRefund.address)
        let derivedFirst = try await lightning.addressInfoForType(
            .nativeSegwit,
            keychain: .external,
            atIndex: firstRefund.index
        )
        XCTAssertEqual(derivedFirst.address, firstRefund.address, "Client-funded orders must refund to the internal Bitkit wallet")

        do {
            _ = try await viewModel.createOrder(clientBalance: 0, lspBalance: 1)
            XCTFail("Expected the staging backend to reject an undersized order")
        } catch {
            XCTAssertEqual(try Bitkit.BlocktankRefundAddressStore().load(), firstRefund)
        }

        try await lightning.stop()
        try await lightning.setup(walletIndex: walletIndex)
        try await lightning.start()
        try await lightning.sync()
        viewModel = makeViewModel()

        let restartedOrder = try await viewModel.createOrder(clientBalance: 0, lspBalance: 100_000)
        XCTAssertEqual(submittedOptions.last?.refundOnchainAddress, firstRefund.address)
        XCTAssertEqual(try Bitkit.BlocktankRefundAddressStore().load(), firstRefund)

        let appCache = try settings.getAppCacheData()
        try await lightning.stop()
        try await lightning.wipeStorage(walletIndex: walletIndex)
        Bitkit.BlocktankRefundAddressStore().clear()
        settings.selectedAddressType = .taproot
        settings.addressTypesToMonitor = [.taproot]
        try settings.restoreAppCacheData(appCache)
        XCTAssertEqual(try Bitkit.BlocktankRefundAddressStore().load(), firstRefund)

        try await lightning.setup(walletIndex: walletIndex)
        try await lightning.start()
        try await lightning.sync()
        await settings.pruneEmptyAddressTypesAfterRestore()
        XCTAssertTrue(settings.addressTypesToMonitor.contains(.nativeSegwit))

        viewModel = makeViewModel()
        let restoredOrder = try await viewModel.createOrder(clientBalance: 0, lspBalance: 100_000)
        XCTAssertEqual(submittedOptions.last?.refundOnchainAddress, firstRefund.address)
        XCTAssertEqual(try Bitkit.BlocktankRefundAddressStore().load(), firstRefund)
        let addressWasUsedBeforeDeposit = try await core.utility.isAddressUsed(address: firstRefund.address)
        XCTAssertFalse(addressWasUsedBeforeDeposit)

        let refundDepositTxId = try await core.blocktank.regtestDepositFunds(address: firstRefund.address, amountSat: 10000)
        XCTAssertFalse(refundDepositTxId.isEmpty)
        try await core.blocktank.regtestMineBlocks(3)

        let activityDeadline = Date().addingTimeInterval(120)
        var recordedPayment = false
        repeat {
            try await lightning.sync()
            if let payments = await lightning.listPayments() {
                try await core.activity.syncLdkNodePayments(payments)
            }
            recordedPayment = try await core.utility.isAddressUsed(address: firstRefund.address)
            if !recordedPayment {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        } while !recordedPayment && Date() < activityDeadline
        XCTAssertTrue(recordedPayment, "Incoming refund-address payment must be recorded in the local activity database")

        let rotatedOrder = try await viewModel.createOrder(clientBalance: 0, lspBalance: 100_000)
        let rotatedRefund = try XCTUnwrap(Bitkit.BlocktankRefundAddressStore().load())
        XCTAssertEqual(rotatedRefund.index, firstRefund.index + 1)
        XCTAssertNotEqual(rotatedRefund.address, firstRefund.address)
        XCTAssertEqual(submittedOptions.last?.refundOnchainAddress, rotatedRefund.address)

        let reusedRotatedOrder = try await viewModel.createOrder(clientBalance: 0, lspBalance: 100_000)
        XCTAssertEqual(try Bitkit.BlocktankRefundAddressStore().load(), rotatedRefund)
        XCTAssertEqual(submittedOptions.last?.refundOnchainAddress, rotatedRefund.address)

        Bitkit.Logger.test(
            "Refund lifecycle orders: first=\(firstOrder.id), clientFunded=\(clientFundedOrder.id), restart=\(restartedOrder.id), " +
                "restore=\(restoredOrder.id), rotated=\(rotatedOrder.id), rotatedReuse=\(reusedRotatedOrder.id); " +
                "refundAddress=\(firstRefund.address), refundIndex=\(firstRefund.index), refundDepositTxId=\(refundDepositTxId), " +
                "rotatedAddress=\(rotatedRefund.address), rotatedIndex=\(rotatedRefund.index)",
            context: "BlocktankRefundAddressLiveIntegrationTests"
        )
    }
}
