@testable import Bitkit
import BitkitCore

/// Shared mocks for the hardware-wallet transfer tests (`HwFundingSignerTests`,
/// `TransferViewModelHwTests`).
@MainActor
final class MockHwFunding: HwTransferFunding {
    struct TestError: Error {}

    var account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
    var accountError: Error?
    var composeError: Error?
    var composeDelay: Double = 0
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
        if composeDelay > 0 { try await Task.sleep(nanoseconds: UInt64(composeDelay * 1_000_000_000)) }
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

@MainActor
final class MockHwConnecting: HwTransferConnecting {
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
