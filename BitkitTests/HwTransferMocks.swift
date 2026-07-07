@testable import Bitkit
import BitkitCore

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
    var signDelay: Double = 0
    var broadcastError: Error?
    var broadcastDelay: Double = 0
    var funding = HwFundingTransaction(psbt: "psbt", miningFeeSats: 141, feeRate: 1, totalSpent: 43186, satsPerVByte: 1)
    var signedTx = HwFundingSignedTx(serializedTx: "rawtx", miningFeeSats: 141, feeRate: 1, totalSpent: 43186)
    var broadcastTxId = "txid"

    private(set) var composeCalls: [(address: String, sats: UInt64, satsPerVByte: UInt64)] = []
    private(set) var maxSpendableCalls: [(address: String, satsPerVByte: UInt64)] = []
    private(set) var signCalls = 0
    private(set) var broadcastCalls = 0

    func getFundingAccount(deviceId _: String, addressType _: AddressScriptType) throws -> HwFundingAccount {
        if let accountError { throw accountError }
        return account
    }

    func maxSpendableFunding(
        deviceId _: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType _: AddressScriptType
    ) async throws -> UInt64 {
        maxSpendableCalls.append((destinationAddress, satsPerVByte))
        if let maxSpendableError { throw maxSpendableError }
        return maxSpendable
    }

    func composeFundingTransaction(
        deviceId _: String,
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

    func signFunding(deviceId _: String, funding _: HwFundingTransaction) async throws -> HwFundingSignedTx {
        signCalls += 1
        if signDelay > 0 { try await Task.sleep(nanoseconds: UInt64(signDelay * 1_000_000_000)) }
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
    private(set) var ensureCalls = 0
    private(set) var staleDisconnects: [String] = []
    private(set) var warmUpCalls: [String] = []

    func ensureConnected(deviceId _: String) async throws {
        ensureCalls += 1
        if let connectError { throw connectError }
    }

    func isKnownBluetoothDevice(deviceId _: String) -> Bool {
        isBluetooth
    }

    func warmUpConnection(deviceId: String) {
        warmUpCalls.append(deviceId)
    }

    func disconnectStaleSession(deviceId: String) async {
        staleDisconnects.append(deviceId)
    }
}
