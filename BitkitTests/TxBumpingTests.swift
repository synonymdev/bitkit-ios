import BitkitCore
import LDKNode
import XCTest

@testable import Bitkit

final class TxBumpingTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    let walletIndex = 0
    let blocktank = CoreService.shared.blocktank
    let lightning = LightningService.shared

    override func setUp() async throws {
        try await super.setUp()
        Logger.test("Starting TX bumping test setup", context: "TxBumpingTests")

        // Wipe the keychain before starting tests
        Logger.test("Wiping keychain before test", context: "TxBumpingTests")
        try Keychain.wipeEntireKeychain()
        Logger.test("Keychain wiped successfully", context: "TxBumpingTests")
    }

    override func tearDown() async throws {
        // Dump LDK logs for debugging
        lightning.dumpLdkLogs()

        // Clean up after each test
        Logger.test("Tearing down TX bumping test", context: "TxBumpingTests")

        // Wipe the keychain after test completion
        Logger.test("Wiping keychain after test", context: "TxBumpingTests")
        try Keychain.wipeEntireKeychain()
        Logger.test("Keychain wiped successfully", context: "TxBumpingTests")

        if lightning.status?.isRunning == true {
            try? await lightning.stop()
        }
        try? await lightning.wipeStorage(walletIndex: walletIndex)
        try await super.tearDown()
    }

    func testBumpFeeByRbf() async throws {
        Logger.test("Starting bump fee by RBF test", context: "TxBumpingTests")

        // Create a new wallet using StartupHandler
        Logger.test("Creating new wallet", context: "TxBumpingTests")
        _ = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        try await lightning.setup(walletIndex: walletIndex)

        Logger.test("Starting lightning node", context: "TxBumpingTests")
        try await lightning.start()
        Logger.test("Lightning node started successfully", context: "TxBumpingTests")

        // Test wallet sync
        Logger.test("Syncing wallet", context: "TxBumpingTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "TxBumpingTests")

        // Generate an address to receive funds
        Logger.test("Generating deposit address", context: "TxBumpingTests")
        let depositAddress = try await lightning.newAddress()
        Logger.test("Deposit address: \(depositAddress)", context: "TxBumpingTests")

        // Fund the wallet with a single transaction
        let depositAmount: UInt64 = 100_000 // 100,000 sats
        Logger.test("Depositing \(depositAmount) sats to wallet", context: "TxBumpingTests")
        try await blocktank.regtestMineBlocks(1)
        let fundingTxId = try await blocktank.regtestDepositFunds(address: depositAddress, amountSat: depositAmount)
        XCTAssertFalse(fundingTxId.isEmpty, "Funding transaction ID should not be empty")
        Logger.test("Funding transaction ID: \(fundingTxId)", context: "TxBumpingTests")

        // Mine blocks to confirm the funding transaction
        Logger.test("Mining 6 blocks to confirm funding transaction", context: "TxBumpingTests")
        try await blocktank.regtestMineBlocks(6)
        Logger.test("Blocks mined successfully", context: "TxBumpingTests")

        // Wait for blocks to be processed
        Logger.test("Waiting 15 seconds for blocks to be processed", context: "TxBumpingTests")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        Logger.test("Wait completed", context: "TxBumpingTests")

        // Sync the wallet to see the new balance
        Logger.test("Syncing wallet to update balances", context: "TxBumpingTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "TxBumpingTests")

        // Verify we have the expected balance
        let balances = lightning.balances
        XCTAssertNotNil(balances, "Balances should not be nil")
        let totalBalance = balances?.totalOnchainBalanceSats ?? 0
        Logger.test("Current balance: \(totalBalance) sats", context: "TxBumpingTests")
        XCTAssertEqual(totalBalance, depositAmount, "Balance should equal deposit amount")

        // Send a transaction with a low fee rate
        let destinationAddress = "bcrt1q59y53uy2h02dlqn76n824ns3maupd3mx4lfm0y"
        let sendAmount: UInt64 = 10000 // Send 10,000 sats
        let lowFeeRate: UInt32 = 1 // 1 sat/vbyte (very low)

        Logger.test("Sending \(sendAmount) sats to \(destinationAddress) with low fee rate of \(lowFeeRate) sat/vbyte", context: "TxBumpingTests")
        let originalTxId = try await lightning.send(
            address: destinationAddress,
            sats: sendAmount,
            satsPerVbyte: lowFeeRate
        )

        try await lightning.sync()

        XCTAssertFalse(originalTxId.isEmpty, "Original transaction ID should not be empty")
        Logger.test("Original transaction sent with txid: \(originalTxId)", context: "TxBumpingTests")

        // Wait a moment before attempting to bump the fee
        Logger.test("Waiting 10 seconds before bumping fee", context: "TxBumpingTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        Logger.test("Wait completed", context: "TxBumpingTests")

        // Bump the fee using RBF with a higher fee rate
        let highFeeRate: UInt32 = 10 // 10 sat/vbyte (much higher)
        Logger.test("Bumping fee for transaction \(originalTxId) to \(highFeeRate) sat/vbyte using RBF", context: "TxBumpingTests")

        let replacementTxId = try await lightning.bumpFeeByRbf(
            txid: originalTxId,
            satsPerVbyte: highFeeRate
        )

        lightning.dumpLdkLogs()

        XCTAssertFalse(replacementTxId.isEmpty, "Replacement transaction ID should not be empty")
        XCTAssertNotEqual(replacementTxId, originalTxId, "Replacement transaction ID should be different from original")
        Logger.test("Fee bumped successfully! Replacement transaction ID: \(replacementTxId)", context: "TxBumpingTests")

        // Mine a block to confirm the replacement transaction
        Logger.test("Mining 1 block to confirm the replacement transaction", context: "TxBumpingTests")
        try await blocktank.regtestMineBlocks(1)
        Logger.test("Block mined successfully", context: "TxBumpingTests")

        // Wait for the block to be processed
        Logger.test("Waiting 10 seconds for block to be processed", context: "TxBumpingTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        Logger.test("Wait completed", context: "TxBumpingTests")

        // Sync the wallet to update balances
        Logger.test("Syncing wallet to update balances after fee bump", context: "TxBumpingTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "TxBumpingTests")

        // Verify the balance has been updated (should be less due to the higher fee)
        let updatedBalances = lightning.balances
        XCTAssertNotNil(updatedBalances, "Updated balances should not be nil")
        let finalBalance = updatedBalances?.totalOnchainBalanceSats ?? 0
        Logger.test("Final balance after fee bump: \(finalBalance) sats", context: "TxBumpingTests")

        // The final balance should be less than the initial balance due to the sent amount and fees
        XCTAssertLessThan(finalBalance, totalBalance, "Final balance should be less than initial balance")
        Logger.test("✓ RBF fee bump test completed successfully", context: "TxBumpingTests")
    }

    func testAccelerateByCpfp() async throws {
        Logger.test("Starting accelerate by CPFP test", context: "TxBumpingTests")

        // Create a new wallet using StartupHandler
        Logger.test("Creating new wallet", context: "TxBumpingTests")
        _ = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        try await lightning.setup(walletIndex: walletIndex)

        Logger.test("Starting lightning node", context: "TxBumpingTests")
        try await lightning.start()
        Logger.test("Lightning node started successfully", context: "TxBumpingTests")

        // Test wallet sync
        Logger.test("Syncing wallet", context: "TxBumpingTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "TxBumpingTests")

        // Generate an address to receive funds
        Logger.test("Generating deposit address", context: "TxBumpingTests")
        let depositAddress = try await lightning.newAddress()
        Logger.test("Deposit address: \(depositAddress)", context: "TxBumpingTests")

        // Simulate receiving a transaction with low fees (this represents someone sending us funds with insufficient fees)
        let incomingAmount: UInt64 = 100_000 // 100,000 sats incoming
        Logger.test("Simulating incoming transaction with low fees: \(incomingAmount) sats", context: "TxBumpingTests")

        // Use blocktank to send us funds with very low fees (simulating a stuck incoming transaction)
        // In a real scenario, this would be someone else sending us funds with insufficient fees
        let stuckIncomingTxId = try await blocktank.regtestDepositFunds(address: depositAddress, amountSat: incomingAmount)
        XCTAssertFalse(stuckIncomingTxId.isEmpty, "Stuck incoming transaction ID should not be empty")
        Logger.test("Stuck incoming transaction ID: \(stuckIncomingTxId)", context: "TxBumpingTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)

        // Sync to see the incoming transaction
        Logger.test("Syncing wallet to detect incoming transaction", context: "TxBumpingTests")
        // try await lightning.sync()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "TxBumpingTests")

        // Check that we can see the balance from the incoming transaction
        let balances = lightning.balances
        XCTAssertNotNil(balances, "Balances should not be nil")
        let currentBalance = balances?.totalOnchainBalanceSats ?? 0
        Logger.test("Current balance: \(currentBalance) sats", context: "TxBumpingTests")

        // The balance should reflect the incoming amount
        XCTAssertGreaterThan(currentBalance, 0, "Should have balance from incoming transaction")
        XCTAssertEqual(currentBalance, incomingAmount, "Balance should equal incoming amount")

        // Now use CPFP to spend from the incoming transaction with high fees
        // This demonstrates using CPFP to quickly move received funds
        let highFeeRate: UInt32 = 20 // 20 sat/vbyte (very high for fast confirmation)
        Logger.test(
            "Using CPFP to quickly spend from incoming transaction \(stuckIncomingTxId) with \(highFeeRate) sat/vbyte", context: "TxBumpingTests"
        )

        // Generate a destination address for the CPFP transaction (where we'll send the funds)
        Logger.test("Generating destination address for CPFP child transaction", context: "TxBumpingTests")
        let cpfpDestinationAddress = try await lightning.newAddress()
        Logger.test("CPFP destination address: \(cpfpDestinationAddress)", context: "TxBumpingTests")

        let childTxId = try await lightning.accelerateByCpfp(
            txid: stuckIncomingTxId,
            satsPerVbyte: highFeeRate,
            destinationAddress: cpfpDestinationAddress
        )

        XCTAssertFalse(childTxId.isEmpty, "CPFP child transaction ID should not be empty")
        XCTAssertNotEqual(childTxId, stuckIncomingTxId, "Child transaction ID should be different from parent")
        Logger.test("CPFP child transaction created successfully! Child transaction ID: \(childTxId)", context: "TxBumpingTests")
        Logger.test("This child transaction spends from the parent and pays high fees for fast confirmation", context: "TxBumpingTests")

        // Mine blocks to confirm the CPFP child transaction
        Logger.test("Mining 2 blocks to confirm the CPFP child transaction", context: "TxBumpingTests")
        try await blocktank.regtestMineBlocks(2)
        Logger.test("Blocks mined successfully - both transactions should now be confirmed", context: "TxBumpingTests")

        // Wait for the blocks to be processed
        Logger.test("Waiting 10 seconds for blocks to be processed", context: "TxBumpingTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        Logger.test("Wait completed", context: "TxBumpingTests")

        // Sync the wallet to update balances
        Logger.test("Syncing wallet to update balances after CPFP confirmation", context: "TxBumpingTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "TxBumpingTests")

        // Verify the final balance
        let finalBalances = lightning.balances
        XCTAssertNotNil(finalBalances, "Final balances should not be nil")
        let finalBalance = finalBalances?.totalOnchainBalanceSats ?? 0
        Logger.test("Final confirmed balance after CPFP: \(finalBalance) sats", context: "TxBumpingTests")

        // We should have received the incoming amount minus the CPFP fees
        // The exact amount depends on the fee calculation, but it should be positive and less than the incoming amount
        XCTAssertGreaterThan(finalBalance, 0, "Should have positive balance after CPFP")
        XCTAssertLessThan(finalBalance, incomingAmount, "Final balance should be less than incoming amount due to CPFP fees")

        Logger.test("✓ CPFP test completed successfully", context: "TxBumpingTests")
        Logger.test("Successfully used CPFP to quickly spend from an incoming transaction", context: "TxBumpingTests")
    }
}
