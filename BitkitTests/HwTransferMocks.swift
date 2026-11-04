@testable import Bitkit
import BitkitCore
import Foundation

/// Shared mocks for the hardware-wallet funding tests (`HwFundingSignerTests`).
@MainActor
final class MockHwFunding: HwTransferFunding {
    struct TestError: Error {}

    var account = HwFundingAccount(xpub: "zpubNS", addressType: .nativeSegwit, balanceSats: 1_000_000)
    var accountError: Error?
    var maxSpendable: UInt64 = 990_000
    var maxSpendableError: Error?
    var composeError: Error?
    var composeDelay: Double = 0
    var estimateDelay: Double = 0
    var signError: Error?
    var signErrors: [Error] = []
    var signDelay: Double = 0
    var cancellationIgnoringSignDelay: Double = 0
    /// Holds every sign until opened, so a test can act while the device is signing.
    var signGate: AsyncGate?
    var broadcastError: Error?
    /// One outcome per broadcast, used before `broadcastError`; nil means that broadcast succeeds.
    var broadcastErrors: [Error?] = []
    var broadcastDelay: Double = 0
    var broadcastNow: () -> Date = Date.init
    /// Holds every broadcast until opened, so a test can act while its outcome is unknown.
    var broadcastGate: AsyncGate?
    var funding = HwFundingTransaction(psbt: "psbt", miningFeeSats: 141, feeRate: 1, totalSpent: 43186, satsPerVByte: 1)
    var signedTx = HwFundingSignedTx(serializedTx: "rawtx", miningFeeSats: 141, feeRate: 1, totalSpent: 43186)
    var broadcastTxId = "txid"

    private(set) var composeCalls: [(address: String, sats: UInt64, satsPerVByte: UInt64)] = []
    private(set) var estimateCalls: [(address: String, sats: UInt64, satsPerVByte: UInt64)] = []
    private(set) var maxSpendableCalls: [(address: String, satsPerVByte: UInt64)] = []
    private(set) var signCalls = 0
    private(set) var broadcastCalls = 0
    private(set) var broadcastTransactions: [String] = []

    func getFundingAccount(walletId _: String, addressType _: AddressScriptType) throws -> HwFundingAccount {
        if let accountError {
            throw accountError
        }
        return account
    }

    func maxSpendableFunding(
        walletId _: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType _: AddressScriptType
    ) async throws -> UInt64 {
        maxSpendableCalls.append((destinationAddress, satsPerVByte))
        if let maxSpendableError {
            throw maxSpendableError
        }
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
        if composeDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(composeDelay * 1_000_000_000))
        }
        if let composeError {
            throw composeError
        }
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
        if estimateDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(estimateDelay * 1_000_000_000))
        }
        if let composeError {
            throw composeError
        }
        return funding.miningFeeSats
    }

    func signFunding(walletId _: String, funding _: HwFundingTransaction) async throws -> HwFundingSignedTx {
        signCalls += 1
        if let signGate {
            await signGate.wait()
        }
        if signDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(signDelay * 1_000_000_000))
        }
        if cancellationIgnoringSignDelay > 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + cancellationIgnoringSignDelay) {
                    continuation.resume()
                }
            }
        }
        if !signErrors.isEmpty {
            throw signErrors.removeFirst()
        }
        if let signError {
            throw signError
        }
        return signedTx
    }

    func broadcastFunding(
        serializedTx: String,
        paymentDeadline: PaykitPreciseInstant? = nil,
        beforeDispatch: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) async throws -> String {
        do {
            try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline, at: broadcastNow())
            try Task.checkCancellation()
            try await beforeDispatch()
            try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline, at: broadcastNow())
            try Task.checkCancellation()
        } catch {
            throw PreparedOnchainSendNotSubmitted(underlying: error)
        }
        broadcastCalls += 1
        broadcastTransactions.append(serializedTx)
        if let broadcastGate {
            await broadcastGate.wait()
        }
        if broadcastDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(broadcastDelay * 1_000_000_000))
        }
        if let error = broadcastErrors.isEmpty ? broadcastError : broadcastErrors.removeFirst() {
            throw error
        }
        return broadcastTxId
    }
}

final class MockHwRetainedSendStore: HwRetainedSendStoring, @unchecked Sendable {
    struct StoreError: Error {}

    private let lock = NSLock()
    private var sends: [String: HwRetainedSend] = [:]
    private var failsLoad = false
    private var failsSave = false
    private var failsDelete = false
    private(set) var deletedWalletIds: [String] = []

    func setFailures(load: Bool = false, save: Bool = false, delete: Bool = false) {
        lock.withLock {
            failsLoad = load
            failsSave = save
            failsDelete = delete
        }
    }

    func load(walletId: String) throws -> HwRetainedSend? {
        try lock.withLock {
            if failsLoad {
                throw StoreError()
            }
            return sends[walletId]
        }
    }

    func save(_ send: HwRetainedSend) throws {
        try lock.withLock {
            if failsSave {
                throw StoreError()
            }
            sends[send.walletId] = send
        }
    }

    func delete(walletId: String) throws {
        try lock.withLock {
            if failsDelete {
                throw StoreError()
            }
            deletedWalletIds.append(walletId)
            sends[walletId] = nil
        }
    }
}

extension HwRetainedSendService {
    /// Lets a test build a coordinator without touching the real keychain record.
    static func inMemory() -> HwRetainedSendService {
        HwRetainedSendService(store: MockHwRetainedSendStore())
    }
}

extension Keychain {
    /// Clears every retained send in the test namespace, whichever wallet it belongs to.
    static func deleteAllRetainedHwSends() throws {
        let prefix = account(for: .hwRetainedSend(walletId: ""))
        for account in getAllKeyChainStorageKeys() where account.hasPrefix(prefix) {
            try delete(key: .hwRetainedSend(walletId: String(account.dropFirst(prefix.count))))
        }
    }
}

@MainActor
final class MockHwConnecting: HwTransferConnecting {
    var connectError: Error?
    var connectDelay: Double = 0
    /// Holds every connect until opened, ignoring cancellation the way a device waiting for its PIN does.
    var connectGate: AsyncGate?
    var reconnectTimeoutSeconds: Double = 5
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
        if let connectGate {
            await connectGate.wait()
        }
        if connectDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(connectDelay * 1_000_000_000))
        }
        if let connectError {
            throw connectError
        }
    }

    func reconnectTimeout(walletId _: String) -> Double {
        reconnectTimeoutSeconds
    }

    func needsPassphrase(walletId: String) -> Bool {
        walletsNeedingPassphrase.contains(walletId)
    }

    func reconnectWithPassphrase(walletId: String, passphrase: String) async throws {
        reconnectCalls.append((walletId, passphrase))
        if let reconnectError {
            throw reconnectError
        }
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
