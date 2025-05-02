//
//  PaymentFlow.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/04/15.
//

import XCTest
@testable import Bitkit

final class PaymentFlowTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    let walletIndex = 0
    let blocktank = CoreService.shared.blocktank
    let lightning = LightningService.shared

    override func setUp() async throws {
        try await super.setUp()
        Logger.test("Starting payment flow test setup", context: "PaymentFlowTests")
        
        // Wipe the keychain before starting tests
        Logger.test("Wiping keychain before test", context: "PaymentFlowTests")
        try Keychain.wipeEntireKeychain()
        Logger.test("Keychain wiped successfully", context: "PaymentFlowTests")
    }
    
    override func tearDown() async throws {
        // Dump LDK logs for debugging
        lightning.dumpLdkLogs()

        // Clean up after each test
        Logger.test("Tearing down payment flow test", context: "PaymentFlowTests")
        
        // Wipe the keychain after test completion
        Logger.test("Wiping keychain after test", context: "PaymentFlowTests")
        try Keychain.wipeEntireKeychain()
        Logger.test("Keychain wiped successfully", context: "PaymentFlowTests")
        
        if lightning.status?.isRunning == true {
            try? await lightning.stop()
        }
        try? await lightning.wipeStorage(walletIndex: walletIndex)
        try await super.tearDown()
    }
    
    func testchannelPurchaseFlow() async throws {
        Logger.test("Starting payment flow test", context: "PaymentFlowTests")
        
        // Create a new wallet using StartupHandler
        Logger.test("Creating new wallet", context: "PaymentFlowTests")
        let mnemonic = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        XCTAssertFalse(mnemonic.isEmpty, "Mnemonic should not be empty")
        Logger.test("Wallet created successfully", context: "PaymentFlowTests")
        
        // Set up the lightning service with the wallet index
        Logger.test("Setting up lightning service with wallet index \(walletIndex)", context: "PaymentFlowTests")
        try await lightning.setup(walletIndex: walletIndex)
        Logger.test("Lightning service setup complete", context: "PaymentFlowTests")
        
        // Start the node
        Logger.test("Starting lightning node", context: "PaymentFlowTests")
        try await lightning.start()
        Logger.test("Lightning node started successfully", context: "PaymentFlowTests")
        
        // Verify node status
        let status = lightning.status
        XCTAssertNotNil(status, "Node status should not be nil")
        Logger.test("Node status: \(String(describing: status))", context: "PaymentFlowTests")
        
        // Verify node ID
        let nodeId = lightning.nodeId
        XCTAssertNotNil(nodeId, "Node ID should not be nil")
        XCTAssertFalse(nodeId?.isEmpty ?? true, "Node ID should not be empty")
        Logger.test("Node ID: \(String(describing: nodeId))", context: "PaymentFlowTests")
        
        // Test wallet sync
        Logger.test("Syncing wallet", context: "PaymentFlowTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "PaymentFlowTests")
        
        // Verify balances
        let balances = lightning.balances
        XCTAssertNotNil(balances, "Balances should not be nil")
        let initialTotal = balances?.totalOnchainBalanceSats ?? 0
        XCTAssertEqual(initialTotal, 0, "Initial balance should be zero")
        Logger.test("Initial balance: \(initialTotal) sats", context: "PaymentFlowTests")
        
        // Generate a new address
        Logger.test("Generating new address", context: "PaymentFlowTests")
        let address = try await lightning.newAddress()
        XCTAssertFalse(address.isEmpty, "Address should not be empty")
        Logger.test("Generated address: \(address)", context: "PaymentFlowTests")
        
        // Test connecting to trusted peers
        Logger.test("Connecting to trusted peers", context: "PaymentFlowTests")
        try await lightning.connectToTrustedPeers()
        Logger.test("Connected to trusted peers", context: "PaymentFlowTests")
        
        // Verify peers
        let peers = lightning.peers
        XCTAssertNotNil(peers, "Peers should not be nil")
        Logger.test("Connected peers: \(String(describing: peers))", context: "PaymentFlowTests")
        
        // Generate an address to receive funds
        Logger.test("Generating deposit address", context: "PaymentFlowTests")
        let depositAddress = try await lightning.newAddress()
        Logger.test("Deposit address: \(depositAddress)", context: "PaymentFlowTests")
        
        // Fund the wallet using regtest deposit function
        let depositAmount: UInt64 = 1_000_000 // 1M sats
        Logger.test("Depositing \(depositAmount) sats to wallet", context: "PaymentFlowTests")
        let txId = try await blocktank.regtestDepositFunds(address: depositAddress, amountSat: depositAmount)
        XCTAssertFalse(txId.isEmpty, "Transaction ID should not be empty")
        Logger.test("Deposit transaction ID: \(txId)", context: "PaymentFlowTests")
        
        // Mine some blocks to confirm the transaction
        Logger.test("Mining 1 block to confirm transaction", context: "PaymentFlowTests")
        try await blocktank.regtestMineBlocks(1)
        Logger.test("Blocks mined successfully", context: "PaymentFlowTests")
        
        //Sleep 10 seconds to ensure the blocks are mined
        Logger.test("Waiting 10 seconds for blocks to be processed", context: "PaymentFlowTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        Logger.test("Wait completed", context: "PaymentFlowTests")

        // Sync the wallet to see the new balance
        Logger.test("Syncing wallet to update balances", context: "PaymentFlowTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "PaymentFlowTests")
        
        // Verify updated balances after funding
        let updatedBalances = lightning.balances
        XCTAssertNotNil(updatedBalances, "Updated balances should not be nil")
        let fundedTotal = updatedBalances?.totalOnchainBalanceSats ?? 0
        XCTAssertGreaterThan(fundedTotal, initialTotal, "Balance should have increased after funding")
        XCTAssertGreaterThanOrEqual(fundedTotal, depositAmount, "Balance should be at least the deposit amount")
        Logger.test("Updated balance: \(fundedTotal) sats", context: "PaymentFlowTests")
        
        // Create an order for 100k sats
        Logger.test("Creating order for 100k sats", context: "PaymentFlowTests")
        let lspBalanceSat: UInt64 = 100_000 // LSP balance (receiving capacity)
        let clientBalanceSat: UInt64 = 0 // Client balance (sending capacity)
        let channelExpiryWeeks: UInt32 = 2
        
        // Create order options with necessary parameters
        let options = CreateOrderOptions(
            clientBalanceSat: clientBalanceSat,
            lspNodeId: nil,
            couponCode: "",
            source: "bitkit-ios-test",
            discountCode: nil,
            zeroConf: true,
            zeroConfPayment: false,
            zeroReserve: true,
            clientNodeId: nodeId,
            signature: nil,
            timestamp: nil,
            refundOnchainAddress: nil,
            announceChannel: false
        )
        
        let order = try await blocktank.newOrder(
            lspBalanceSat: lspBalanceSat,
            channelExpiryWeeks: channelExpiryWeeks,
            options: options
        )
        
        XCTAssertNotNil(order, "Order should not be nil")
        XCTAssertFalse(order.id.isEmpty, "Order ID should not be empty")
        XCTAssertEqual(order.state2, .created, "Initial order state should be created")
        XCTAssertGreaterThan(order.feeSat, 0, "Fee should be greater than 0")
        Logger.test("Order created successfully with ID: \(order.id)", context: "PaymentFlowTests")
        Logger.test("Order fee: \(order.feeSat) sats", context: "PaymentFlowTests")
        
        // Pay the order
        Logger.test("Paying order with fee \(order.feeSat) sats to address \(order.payment.onchain.address)", context: "PaymentFlowTests")
        let paymentTxId = try await lightning.send(address: order.payment.onchain.address, sats: order.feeSat, satsPerVbyte: 1)
        XCTAssertFalse(paymentTxId.isEmpty, "Payment transaction ID should not be empty")
        Logger.test("Payment sent with transaction ID: \(paymentTxId)", context: "PaymentFlowTests")

        //Mine 1 block to confirm the payment transaction
        try await Task.sleep(nanoseconds: 500_000_000)
        try await blocktank.regtestMineBlocks(1)
        Logger.test("Block mined successfully", context: "PaymentFlowTests")
        
        // Sleep 10 seconds to ensure the order is processed and then mine blocks again
        Logger.test("Waiting 10 seconds for payment to be processed", context: "PaymentFlowTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        Logger.test("Wait completed", context: "PaymentFlowTests")
        
        // Mine blocks to confirm the payment transaction
        Logger.test("Mining blocks to confirm payment", context: "PaymentFlowTests")
        try await blocktank.regtestMineBlocks(6)
        Logger.test("Blocks mined successfully", context: "PaymentFlowTests")
        
        // Sync wallet again
        Logger.test("Syncing wallet after payment", context: "PaymentFlowTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "PaymentFlowTests")
        
        // Check the order status
        Logger.test("Checking order status", context: "PaymentFlowTests")
        let updatedOrders = try await blocktank.orders(orderIds: [order.id], filter: nil, refresh: true)
        XCTAssertFalse(updatedOrders.isEmpty, "Updated orders should not be empty")
        
        guard let updatedOrder = updatedOrders.first else {
            XCTFail("Could not retrieve updated order")
            return
        }
        
        Logger.test("Updated order state: \(updatedOrder.state2)", context: "PaymentFlowTests")
        XCTAssertEqual(updatedOrder.state2, .paid, "Order state should be paid after payment confirmation")
        
        // Request channel to be opened
        Logger.test("Requesting channel to be opened", context: "PaymentFlowTests")
        let openedOrder = try await blocktank.open(orderId: order.id)
        XCTAssertEqual(openedOrder.state2, .executed, "Order state should be executed after opening channel")
        Logger.test("Channel opening requested successfully", context: "PaymentFlowTests")
        
        // Wait for the channel to be established
        Logger.test("Waiting for channel to be established", context: "PaymentFlowTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        
        // Sync wallet to see the new channel
        Logger.test("Syncing wallet to see new channel", context: "PaymentFlowTests")
        try await lightning.sync()
        
        // Verify channel exists
        let channels = lightning.channels
        XCTAssertNotNil(channels, "Channels should not be nil")
        XCTAssertGreaterThan(channels?.count ?? 0, 0, "Should have at least one channel")
        
        // Check if we have at least one usable channel
        let usableChannels = channels?.filter { $0.isUsable } ?? []
        XCTAssertGreaterThan(usableChannels.count, 0, "Should have at least one usable channel")
        
        if let firstUsableChannel = usableChannels.first {
            Logger.test("Usable channel established with capacity: \(firstUsableChannel.channelValueSats) sats", context: "PaymentFlowTests")
            Logger.test("Channel counterparty: \(firstUsableChannel.counterpartyNodeId)", context: "PaymentFlowTests")
            
            // Verify channel properties
            XCTAssertTrue(firstUsableChannel.isUsable, "Channel should be usable")
            XCTAssertTrue(firstUsableChannel.isChannelReady, "Channel should be ready")
            XCTAssertEqual(firstUsableChannel.channelValueSats, lspBalanceSat, "Channel capacity should match requested amount")
        } else if let firstChannel = channels?.first {
            Logger.test("Channel exists but is not yet usable. State: isChannelReady=\(firstChannel.isChannelReady), isUsable=\(firstChannel.isUsable)", context: "PaymentFlowTests")
            Logger.test("Channel capacity: \(firstChannel.channelValueSats) sats", context: "PaymentFlowTests")
            Logger.test("Channel counterparty: \(firstChannel.counterpartyNodeId)", context: "PaymentFlowTests")
            XCTFail("Channel exists but is not usable yet")
        }

        //TODO: actually try route some payments

        // Clean up by removing the test wallet
        Logger.test("Stopping lightning node", context: "PaymentFlowTests")
        try await lightning.stop()
        Logger.test("Lightning node stopped successfully", context: "PaymentFlowTests")
        Logger.test("Payment flow test completed successfully", context: "PaymentFlowTests")
    }
}
