//
//  UtxoSelectionTests.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2025/06/12.
//

import BitkitCore
import XCTest
import LDKNode

@testable import Bitkit

final class UtxoSelectionTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    let walletIndex = 0
    let blocktank = CoreService.shared.blocktank
    let lightning = LightningService.shared

    override func setUp() async throws {
        try await super.setUp()
        Logger.test("Starting UTXO selection test setup", context: "UtxoSelectionTests")

        // Wipe the keychain before starting tests
        Logger.test("Wiping keychain before test", context: "UtxoSelectionTests")
        try Keychain.wipeEntireKeychain()
        Logger.test("Keychain wiped successfully", context: "UtxoSelectionTests")
    }

    override func tearDown() async throws {
        // Dump LDK logs for debugging
        lightning.dumpLdkLogs()

        // Clean up after each test
        Logger.test("Tearing down UTXO selection test", context: "UtxoSelectionTests")

        // Wipe the keychain after test completion
        Logger.test("Wiping keychain after test", context: "UtxoSelectionTests")
        try Keychain.wipeEntireKeychain()
        Logger.test("Keychain wiped successfully", context: "UtxoSelectionTests")

        if lightning.status?.isRunning == true {
            try? await lightning.stop()
        }
        try? await lightning.wipeStorage(walletIndex: walletIndex)
        try await super.tearDown()
    }

    func testUtxoSelection() async throws {
        Logger.test("Starting UTXO selection test", context: "UtxoSelectionTests")

        // Create a new wallet using StartupHandler
        Logger.test("Creating new wallet", context: "UtxoSelectionTests")
        let _ = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        try await lightning.setup(walletIndex: walletIndex)

        Logger.test("Starting lightning node", context: "UtxoSelectionTests")
        try await lightning.start()
        Logger.test("Lightning node started successfully", context: "UtxoSelectionTests")

        // Test wallet sync
        Logger.test("Syncing wallet", context: "UtxoSelectionTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "UtxoSelectionTests")

        // Generate an address to receive funds
        Logger.test("Generating deposit address", context: "UtxoSelectionTests")
        let depositAddress = try await lightning.newAddress()
        Logger.test("Deposit address: \(depositAddress)", context: "UtxoSelectionTests")

        // Define different deposit amounts for 5 transactions
        let depositAmounts: [UInt64] = [15_000, 25_000, 35_000, 45_000, 50_000] // Different amounts in sats
        var totalExpectedAmount: UInt64 = 0
        var transactionIds: [String] = []

        // Fund the wallet with multiple transactions
        for (index, depositAmount) in depositAmounts.enumerated() {
            Logger.test(
                "Depositing \(depositAmount) sats to wallet (transaction \(index + 1)/\(depositAmounts.count))", context: "UtxoSelectionTests")
            let txId = try await blocktank.regtestDepositFunds(address: depositAddress, amountSat: depositAmount)
            XCTAssertFalse(txId.isEmpty, "Transaction ID should not be empty")
            transactionIds.append(txId)
            totalExpectedAmount += depositAmount
            Logger.test("Deposit transaction \(index + 1) ID: \(txId), Amount: \(depositAmount) sats", context: "UtxoSelectionTests")
        }

        Logger.test("Total expected amount from all deposits: \(totalExpectedAmount) sats", context: "UtxoSelectionTests")
        Logger.test("All transaction IDs: \(transactionIds)", context: "UtxoSelectionTests")

        // Mine some blocks to confirm all transactions
        Logger.test("Mining 6 blocks to confirm all transactions", context: "UtxoSelectionTests")
        try await blocktank.regtestMineBlocks(6)
        Logger.test("Blocks mined successfully", context: "UtxoSelectionTests")

        // Sleep 15 seconds to ensure all blocks are processed
        Logger.test("Waiting 15 seconds for blocks to be processed", context: "UtxoSelectionTests")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        Logger.test("Wait completed", context: "UtxoSelectionTests")

        // Sync the wallet to see the new balance
        Logger.test("Syncing wallet to update balances", context: "UtxoSelectionTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "UtxoSelectionTests")

        // Verify updated balances after funding
        let updatedBalances = lightning.balances
        XCTAssertNotNil(updatedBalances, "Updated balances should not be nil")
        let finalTotal = updatedBalances?.totalOnchainBalanceSats ?? 0

        Logger.test("Final balance: \(finalTotal) sats", context: "UtxoSelectionTests")
        Logger.test("Expected total: \(totalExpectedAmount) sats", context: "UtxoSelectionTests")

        // Verify the final balance matches the total expected amount
        XCTAssertEqual(finalTotal, totalExpectedAmount, "Final balance should equal the sum of all deposits")
        XCTAssertGreaterThan(finalTotal, 0, "Final balance should be greater than 0")

        // List utxos and make sure we have the right amount
        Logger.test("Listing UTXOs to verify amounts", context: "UtxoSelectionTests")
        let outputs = try await lightning.listSpendableOutputs()
        Logger.test("Found \(outputs.count) spendable outputs", context: "UtxoSelectionTests")
        XCTAssertEqual(outputs.count, depositAmounts.count, "Number of UTXOs should match number of deposits")

        // Validate each spendable output matches one of the deposit amounts
        var remainingDepositAmounts = depositAmounts
        for output in outputs {
            Logger.test("UTXO: \(output.outpoint.txid) with amount \(output.valueSats) sats", context: "UtxoSelectionTests")

            // Check if this output amount matches one of our expected deposit amounts
            if let index = remainingDepositAmounts.firstIndex(of: output.valueSats) {
                Logger.test("✓ UTXO amount \(output.valueSats) sats matches expected deposit amount", context: "UtxoSelectionTests")
                remainingDepositAmounts.remove(at: index)
            } else {
                XCTFail("UTXO amount \(output.valueSats) sats does not match any expected deposit amount. Expected amounts: \(depositAmounts)")
            }
        }

        // Ensure all deposit amounts were matched
        XCTAssertTrue(
            remainingDepositAmounts.isEmpty, "Not all deposit amounts were matched. Remaining unmatched amounts: \(remainingDepositAmounts)")
        Logger.test("✓ All spendable outputs successfully matched with deposit amounts", context: "UtxoSelectionTests")

        // Test a transaction spending specific utxos
        Logger.test("Testing transaction spending specific UTXOs", context: "UtxoSelectionTests")

        // Select the first 2 UTXOs to spend
        let utxosToSpend = Array(outputs.prefix(2))
        let selectedUtxoIds = utxosToSpend.map { "\($0.outpoint.txid):\($0.outpoint.vout)" }
        let totalSelectedAmount = utxosToSpend.reduce(0) { $0 + $1.valueSats }

        Logger.test("Selected \(utxosToSpend.count) UTXOs to spend:", context: "UtxoSelectionTests")
        for (index, utxo) in utxosToSpend.enumerated() {
            Logger.test(
                "  UTXO \(index + 1): \(utxo.outpoint.txid):\(utxo.outpoint.vout) - \(utxo.valueSats) sats", context: "UtxoSelectionTests")
        }
        Logger.test("Total amount from selected UTXOs: \(totalSelectedAmount) sats", context: "UtxoSelectionTests")

        // Send transaction spending only the selected UTXOs
        let destinationAddress = "bcrt1q59y53uy2h02dlqn76n824ns3maupd3mx4lfm0y"
        let sendAmount: UInt64 = 10_000 // Send 10,000 sats
        let feeRate: UInt32 = 1 // 1 sat/vbyte

        Logger.test("Sending \(sendAmount) sats to \(destinationAddress) using specific UTXOs", context: "UtxoSelectionTests")
        let txId = try await lightning.send(
            address: destinationAddress,
            sats: sendAmount,
            satsPerVbyte: feeRate,
            utxosToSpend: utxosToSpend
        )

        XCTAssertFalse(txId.isEmpty, "Transaction ID should not be empty")
        Logger.test("Transaction sent successfully with txid: \(txId)", context: "UtxoSelectionTests")

        // Mine a block to confirm the transaction
        Logger.test("Mining 1 block to confirm the transaction", context: "UtxoSelectionTests")
        try await blocktank.regtestMineBlocks(1)
        Logger.test("Block mined successfully", context: "UtxoSelectionTests")

        // Wait for the block to be processed
        Logger.test("Waiting 10 seconds for block to be processed", context: "UtxoSelectionTests")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        Logger.test("Wait completed", context: "UtxoSelectionTests")

        // Sync the wallet to update UTXOs
        Logger.test("Syncing wallet to update UTXO set", context: "UtxoSelectionTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "UtxoSelectionTests")

        // List UTXOs again and verify the spent ones are missing
        Logger.test("Listing UTXOs after spending to verify the spent ones are missing", context: "UtxoSelectionTests")
        let remainingOutputs = try await lightning.listSpendableOutputs()
        Logger.test("Found \(remainingOutputs.count) remaining spendable outputs", context: "UtxoSelectionTests")

        // Verify the specific UTXOs we spent are no longer in the list
        let remainingUtxoIds = remainingOutputs.map { "\($0.outpoint.txid):\($0.outpoint.vout)" }
        for spentUtxoId in selectedUtxoIds {
            XCTAssertFalse(remainingUtxoIds.contains(spentUtxoId), "Spent UTXO \(spentUtxoId) should not be in remaining outputs")
            Logger.test("✓ Confirmed UTXO \(spentUtxoId) is no longer spendable", context: "UtxoSelectionTests")
        }

        // Verify the remaining UTXOs are the ones we didn't spend
        let originalUtxoIds = outputs.map { "\($0.outpoint.txid):\($0.outpoint.vout)" }
        let expectedRemainingIds = originalUtxoIds.filter { !selectedUtxoIds.contains($0) }

        for expectedId in expectedRemainingIds {
            XCTAssertTrue(remainingUtxoIds.contains(expectedId), "Expected remaining UTXO \(expectedId) should still be spendable")
        }

        Logger.test("✓ Successfully verified that the 2 selected UTXOs were spent and are no longer available", context: "UtxoSelectionTests")

        // Clean up by stopping the lightning node
        Logger.test("Stopping lightning node", context: "UtxoSelectionTests")
        try await lightning.stop()
        Logger.test("Lightning node stopped successfully", context: "UtxoSelectionTests")
        Logger.test(
            "UTXO selection test completed successfully with \(depositAmounts.count) transactions totaling \(totalExpectedAmount) sats",
            context: "UtxoSelectionTests")
    }

    func testUtxoSelectionAlgorithms() async throws {
        Logger.test("Starting UTXO selection algorithms test", context: "UtxoSelectionTests")

        // Create a new wallet using StartupHandler
        Logger.test("Creating new wallet", context: "UtxoSelectionTests")
        let _ = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        try await lightning.setup(walletIndex: walletIndex)

        Logger.test("Starting lightning node", context: "UtxoSelectionTests")
        try await lightning.start()
        Logger.test("Lightning node started successfully", context: "UtxoSelectionTests")

        // Test wallet sync
        Logger.test("Syncing wallet", context: "UtxoSelectionTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "UtxoSelectionTests")

        // Generate an address to receive funds
        Logger.test("Generating deposit address", context: "UtxoSelectionTests")
        let depositAddress = try await lightning.newAddress()
        Logger.test("Deposit address: \(depositAddress)", context: "UtxoSelectionTests")

        // Define different deposit amounts for testing coin selection algorithms
        let depositAmounts: [UInt64] = [5_000, 10_000, 20_000, 30_000, 50_000] // Different amounts in sats
        var totalExpectedAmount: UInt64 = 0

        // Fund the wallet with multiple transactions
        for (index, depositAmount) in depositAmounts.enumerated() {
            Logger.test(
                "Depositing \(depositAmount) sats to wallet (transaction \(index + 1)/\(depositAmounts.count))",
                context: "UtxoSelectionTests")
            let txId = try await blocktank.regtestDepositFunds(address: depositAddress, amountSat: depositAmount)
            XCTAssertFalse(txId.isEmpty, "Transaction ID should not be empty")
            totalExpectedAmount += depositAmount
            Logger.test("Deposit transaction \(index + 1) ID: \(txId), Amount: \(depositAmount) sats", context: "UtxoSelectionTests")
        }

        Logger.test("Total expected amount from all deposits: \(totalExpectedAmount) sats", context: "UtxoSelectionTests")

        // Mine blocks to confirm all transactions
        Logger.test("Mining 6 blocks to confirm all transactions", context: "UtxoSelectionTests")
        try await blocktank.regtestMineBlocks(6)
        Logger.test("Blocks mined successfully", context: "UtxoSelectionTests")

        // Wait for blocks to be processed
        Logger.test("Waiting 15 seconds for blocks to be processed", context: "UtxoSelectionTests")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        Logger.test("Wait completed", context: "UtxoSelectionTests")

        // Sync the wallet to see the new balance
        Logger.test("Syncing wallet to update balances", context: "UtxoSelectionTests")
        try await lightning.sync()
        Logger.test("Wallet sync complete", context: "UtxoSelectionTests")

        // Get all available UTXOs
        Logger.test("Listing all available UTXOs", context: "UtxoSelectionTests")
        let allUtxos = try await lightning.listSpendableOutputs()
        Logger.test("Found \(allUtxos.count) spendable outputs", context: "UtxoSelectionTests")
        XCTAssertEqual(allUtxos.count, depositAmounts.count, "Number of UTXOs should match number of deposits")

        // Test parameters
        let targetAmountSats: UInt64 = 25_000 // Target amount for selection
        let feeRate: UInt32 = 1 // 1 sat/vbyte

        // Test each coin selection algorithm
        let algorithms: [CoinSelectionAlgorithm] = [.branchAndBound, .largestFirst, .oldestFirst, .singleRandomDraw]

        for algorithm in algorithms {
            Logger.test("Testing coin selection algorithm: \(algorithm)", context: "UtxoSelectionTests")

            let selectedUtxos = try await lightning.selectUtxosWithAlgorithm(
                targetAmountSats: targetAmountSats,
                satsPerVbyte: feeRate,
                coinSelectionAlgorythm: algorithm,
                utxos: allUtxos
            )

            XCTAssertFalse(selectedUtxos.isEmpty, "Selected UTXOs should not be empty for algorithm \(algorithm)")

            let selectedAmount = selectedUtxos.reduce(0) { $0 + $1.valueSats }
            Logger.test(
                "Algorithm \(algorithm) selected \(selectedUtxos.count) UTXOs with total amount: \(selectedAmount) sats",
                context: "UtxoSelectionTests")

            // Verify that the selected amount is sufficient for the target amount
            XCTAssertGreaterThanOrEqual(
                selectedAmount, targetAmountSats, "Selected amount should be at least the target amount for algorithm \(algorithm)")

            // Log details of selected UTXOs
            for (index, utxo) in selectedUtxos.enumerated() {
                Logger.test(
                    "  UTXO \(index + 1): \(utxo.outpoint.txid):\(utxo.outpoint.vout) - \(utxo.valueSats) sats", context: "UtxoSelectionTests")
            }

            Logger.test("✓ Algorithm \(algorithm) successfully selected UTXOs", context: "UtxoSelectionTests")
        }

        // Test algorithm-specific behavior with different target amounts
        Logger.test("Testing algorithm-specific behaviors with different target amounts", context: "UtxoSelectionTests")

        // Test with small amount (should prefer smaller UTXOs)
        let smallTargetAmount: UInt64 = 7_000
        let smallAmountUtxos = try await lightning.selectUtxosWithAlgorithm(
            targetAmountSats: smallTargetAmount,
            satsPerVbyte: feeRate,
            coinSelectionAlgorythm: .largestFirst,
            utxos: allUtxos
        )
        Logger.test("Largest first for \(smallTargetAmount) sats selected \(smallAmountUtxos.count) UTXOs", context: "UtxoSelectionTests")

        // Test with large amount (might need multiple UTXOs)
        let largeTargetAmount: UInt64 = 80_000
        let largeAmountUtxos = try await lightning.selectUtxosWithAlgorithm(
            targetAmountSats: largeTargetAmount,
            satsPerVbyte: feeRate,
            coinSelectionAlgorythm: .largestFirst,
            utxos: allUtxos
        )
        Logger.test("Largest first for \(largeTargetAmount) sats selected \(largeAmountUtxos.count) UTXOs", context: "UtxoSelectionTests")

        let largeSelectedAmount = largeAmountUtxos.reduce(0) { $0 + $1.valueSats }
        XCTAssertGreaterThanOrEqual(largeSelectedAmount, largeTargetAmount, "Should select enough UTXOs for large amount")

        // Test passing a subset of UTXOs
        Logger.test("Testing coin selection with subset of UTXOs", context: "UtxoSelectionTests")
        let subsetUtxos = Array(allUtxos.prefix(3)) // Use only first 3 UTXOs
        let subsetSelectedUtxos = try await lightning.selectUtxosWithAlgorithm(
            targetAmountSats: 15_000,
            satsPerVbyte: feeRate,
            coinSelectionAlgorythm: .branchAndBound,
            utxos: subsetUtxos
        )
        Logger.test(
            "Branch and bound with subset selected \(subsetSelectedUtxos.count) UTXOs from \(subsetUtxos.count) available",
            context: "UtxoSelectionTests")

        // Clean up by stopping the lightning node
        Logger.test("Stopping lightning node", context: "UtxoSelectionTests")
        try await lightning.stop()
        Logger.test("Lightning node stopped successfully", context: "UtxoSelectionTests")
        Logger.test("UTXO selection algorithms test completed successfully", context: "UtxoSelectionTests")
    }
}
