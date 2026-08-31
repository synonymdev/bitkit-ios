@testable import Bitkit
import BitkitCore
import Foundation

/// Shared mocks for the hardware-wallet transfer tests (`HwFundingSignerTests`,
/// `TransferViewModelHwTests`).
@MainActor
final class MockHwFunding: HwTransferFunding {
    struct TestError: Error {}

    var account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
    var accountError: Error?
    var maxSpendable: UInt64 = 990_000
    var maxSpendableError: Error?
    var composeError: Error?
    var composeDelay: Double = 0
    var signError: Error?
    var signErrors: [Error] = []
    var signDelay: Double = 0
    var cancellationIgnoringSignDelay: Double = 0
    var broadcastError: Error?
    var broadcastDelay: Double = 0
    var funding = HwFundingTransaction(psbt: "psbt", miningFeeSats: 141, feeRate: 1, totalSpent: 43186, satsPerVByte: 1)
    var signedTx = HwFundingSignedTx(serializedTx: "rawtx", miningFeeSats: 141, feeRate: 1, totalSpent: 43186)
    var broadcastTxId = "txid"

    private(set) var composeCalls: [(address: String, sats: UInt64, satsPerVByte: UInt64)] = []
    private(set) var estimateCalls: [(address: String, sats: UInt64, satsPerVByte: UInt64)] = []
    private(set) var maxSpendableCalls: [(address: String, satsPerVByte: UInt64)] = []
    private(set) var signCalls = 0
    private(set) var broadcastCalls = 0

    func getFundingAccount(walletId _: String, addressType _: AddressScriptType) throws -> HwFundingAccount {
        if let accountError { throw accountError }
        return account
    }

    func maxSpendableFunding(
        walletId _: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType _: AddressScriptType
    ) async throws -> UInt64 {
        maxSpendableCalls.append((destinationAddress, satsPerVByte))
        if let maxSpendableError { throw maxSpendableError }
        return maxSpendable
    }

    func composeFundingTransaction(
        walletId _: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType _: AddressScriptType
    ) async throws -> HwFundingTransaction {
        composeCalls.append((address, sats, satsPerVByte))
        if composeDelay > 0 { try await Task.sleep(nanoseconds: UInt64(composeDelay * 1_000_000_000)) }
        if let composeError { throw composeError }
        return funding
    }

    func estimateOfflineFundingMiningFee(
        walletId _: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType _: AddressScriptType
    ) async throws -> UInt64 {
        estimateCalls.append((address, sats, satsPerVByte))
        if let composeError { throw composeError }
        return funding.miningFeeSats
    }

    func signFunding(walletId _: String, funding _: HwFundingTransaction) async throws -> HwFundingSignedTx {
        signCalls += 1
        if signDelay > 0 { try await Task.sleep(nanoseconds: UInt64(signDelay * 1_000_000_000)) }
        if cancellationIgnoringSignDelay > 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + cancellationIgnoringSignDelay) {
                    continuation.resume()
                }
            }
        }
        if !signErrors.isEmpty { throw signErrors.removeFirst() }
        if let signError { throw signError }
        return signedTx
    }

    func broadcastFunding(serializedTx _: String) async throws -> String {
        broadcastCalls += 1
        if broadcastDelay > 0 { try await Task.sleep(nanoseconds: UInt64(broadcastDelay * 1_000_000_000)) }
        if let broadcastError { throw broadcastError }
        return broadcastTxId
    }
}

@MainActor
final class MockHwConnecting: HwTransferConnecting {
    var connectError: Error?
    var isBluetooth = false
    /// Wallets whose passphrase the device no longer holds, so signing has to ask for it again.
    var walletsNeedingPassphrase: Set<String> = []
    var reconnectError: Error?
    private(set) var ensureCalls = 0
    private(set) var staleDisconnects: [String] = []
    private(set) var warmUpCalls: [String] = []
    private(set) var reconnectCalls: [(walletId: String, passphrase: String)] = []

    func ensureConnected(walletId _: String) async throws {
        ensureCalls += 1
        if let connectError { throw connectError }
    }

    func needsPassphrase(walletId: String) -> Bool {
        walletsNeedingPassphrase.contains(walletId)
    }

    func reconnectWithPassphrase(walletId: String, passphrase: String) async throws {
        reconnectCalls.append((walletId, passphrase))
        if let reconnectError { throw reconnectError }
        walletsNeedingPassphrase.remove(walletId)
    }

    func isKnownBluetoothDevice(walletId _: String) -> Bool {
        isBluetooth
    }

    func warmUpConnection(walletId: String) {
        warmUpCalls.append(walletId)
    }

    func disconnectStaleSession(walletId: String) async {
        staleDisconnects.append(walletId)
    }

    func scheduleStaleSessionCleanup(walletId: String) {
        staleDisconnects.append(walletId)
    }
}
