import BitkitCore
import Combine
import CryptoKit
import Foundation
import Observation

@Observable @MainActor
final class UsdtWalletManager {
    private nonisolated(unsafe) static let backupStateChanged = PassthroughSubject<Void, Never>()
    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        backupStateChanged.eraseToAnyPublisher()
    }

    let receivedTxPublisher = PassthroughSubject<UsdtTransfer, Never>()
    private(set) var balance: UInt64?
    private(set) var address = ""
    private(set) var receiveUri = ""
    private(set) var transfers: [UsdtTransfer] = [] {
        didSet { if oldValue != transfers { Self.backupStateChanged.send() } }
    }

    private(set) var historyComplete = false
    private(set) var refreshing = false
    var errorMessage: String?
    var isSendPresented = false
    private var core: UsdtWallet?
    private var credentialFingerprint: SHA256.Digest?
    private let storageDirectory: URL
    private var wiping = false
    private var activeOperations = 0
    private var initialization: Task<UsdtWallet, Error>?
    private var wipeTask: Task<Void, Error>?
    private var nextRefresh = Date.distantPast
    private var rateLimitedUntil = Date.distantPast
    private var idleWaiter: CheckedContinuation<Void, Never>?

    var isConfigured: Bool {
        Env.isUsdtEnabled
    }

    var networkName: String {
        "Arbitrum One"
    }

    init(storageDirectory: URL = Env.bitkitCoreStorage(walletIndex: 0)) {
        self.storageDirectory = storageDirectory
    }

    func refresh(includeHistory: Bool = false) async {
        guard isConfigured, !refreshing, !wiping else { return }
        guard Date() >= max(nextRefresh, rateLimitedUntil) else { return }
        var refreshDelay: TimeInterval = 10
        activeOperations += 1
        refreshing = true
        defer { refreshing = false; nextRefresh = max(rateLimitedUntil, Date().addingTimeInterval(refreshDelay)); finishOperation() }
        do {
            let wallet = try await wallet()
            let previousTransfers = historyComplete ? transfers : nil
            transfers = try await ServiceQueue.background(.core, wrapErrors: false) { try wallet.history() }
            var settlementError: Error?
            do {
                balance = try await wallet.balance()
                transfers = try await wallet.refreshTransfers()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let error = error as? UsdtError, case .RateLimited = error { throw error }
                settlementError = error
            }
            try Task.checkCancellation()
            if includeHistory, !isSendPresented {
                let complete = try await wallet.syncHistory()
                historyComplete = historyComplete || complete
                transfers = try await ServiceQueue.background(.core, wrapErrors: false) { try wallet.history() }
                for transfer in Self.newIncomingTransfers(previous: previousTransfers, current: transfers) {
                    receivedTxPublisher.send(transfer)
                }
            }
            if let settlementError { throw settlementError }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if let error = error as? UsdtError, case .RateLimited = error { refreshDelay = 60; rateLimitedUntil = Date().addingTimeInterval(60) }
            errorMessage = Self.message(for: error)
            Logger.warn("Failed to refresh USDT: \(Self.message(for: error))", context: "UsdtWalletManager")
        }
    }

    static func newIncomingTransfers(previous: [UsdtTransfer]?, current: [UsdtTransfer]) -> [UsdtTransfer] {
        guard let previous else { return [] }
        let knownIds = Set(previous.filter { $0.isIncoming && $0.status == .confirmed }.map(\.id))
        return current.filter { $0.isIncoming && $0.status == .confirmed && $0.amount > 0 && !knownIds.contains($0.id) }
    }

    func quote(recipient: String, amount: String, destination: UsdtDestination) async throws -> UsdtQuote {
        try beginOperation()
        defer { finishOperation() }
        let value = try usdtParseAmount(value: amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
        let wallet = try await wallet()
        return try await wallet.quoteTransfer(recipient: recipient, amount: value, destination: destination)
    }

    func backupSnapshot() async throws -> String? {
        guard isConfigured else {
            if FileManager.default.fileExists(atPath: storageDirectory.path) {
                let files = try FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
                guard !files.contains(where: { $0.lastPathComponent.hasPrefix("usdt-") && $0.pathExtension == "sqlite" }) else {
                    throw UsdtError.NotConfigured
                }
            }
            return nil
        }
        try beginOperation()
        defer { finishOperation() }
        let wallet = try await wallet()
        return try await ServiceQueue.background(.core, wrapErrors: false) { try wallet.exportBackup() }
    }

    func restoreBackup(_ snapshot: String) async throws {
        try beginOperation()
        defer { finishOperation() }
        let wallet = try await wallet()
        try await wallet.restoreBackup(snapshot: snapshot)
        transfers = try wallet.history()
        historyComplete = false
    }

    func paymentEndpoint() async throws -> PublicPaykitService.Endpoint {
        try beginOperation()
        defer { finishOperation() }
        let wallet = try await wallet()
        return try PaykitUsdt.endpoint(address: wallet.receiveAddress())
    }

    func send(_ quote: UsdtQuote, beforeSubmission: @escaping @MainActor () async throws -> Void = {}) async throws {
        try beginOperation()
        defer { finishOperation() }
        let wallet = try await wallet()
        let transfer = try await ServiceQueue.background(.core, wrapErrors: false) {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else { throw UsdtError.InvalidCredentials }
            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0))
            try await beforeSubmission()
            return try await wallet.send(quoteId: quote.id, mnemonic: mnemonic, passphrase: passphrase)
        }
        transfers.removeAll { $0.id == transfer.id }
        transfers.insert(transfer, at: 0)
    }

    func paymentProof(quoteId: String, binding: UsdtPaymentProofBinding) async throws -> UsdtPaymentProof? {
        try beginOperation()
        defer { finishOperation() }
        let core = try await wallet()
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else { throw UsdtError.InvalidCredentials }
        return try await core.createPaymentProof(transferId: quoteId, binding: binding, mnemonic: mnemonic,
                                                 passphrase: Keychain.loadString(key: .bip39Passphrase(index: 0)))
    }

    func storedTransfer(_ id: String) async throws -> UsdtTransfer? {
        try beginOperation()
        defer { finishOperation() }
        let core = try await wallet()
        return try await ServiceQueue.background(.core, wrapErrors: false) { try core.history().first { $0.id == id } }
    }

    func verifyPayment(binding: UsdtPaymentProofBinding, proof: UsdtPaymentProof) async throws -> UsdtVerifiedPayment? {
        try beginOperation()
        defer { finishOperation() }
        return try await wallet().verifyPaymentProof(binding: binding, proof: proof)
    }

    func waitForTransfer(_ id: String) async {
        guard isConfigured, !wiping, !refreshing, !Task.isCancelled, Date() >= rateLimitedUntil else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            try beginOperation()
            defer { finishOperation() }
            let wallet = try await wallet()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                try Task.checkCancellation()
                let transfer = try await Task.detached { try await wallet.checkRecentExecution(id: id) }.value
                try Task.checkCancellation()
                guard let transfer else { return }
                transfers.removeAll { $0.id == transfer.id }
                transfers.insert(transfer, at: 0)
                errorMessage = nil
                if transfer.status != .pending { return }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
        } catch {
            if let error = error as? UsdtError, case .RateLimited = error {
                rateLimitedUntil = Date().addingTimeInterval(60)
                nextRefresh = max(nextRefresh, rateLimitedUntil)
            }
            guard !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
            Logger.warn("Failed to check USDT payment: \(Self.message(for: error))", context: "UsdtWalletManager")
        }
    }

    var depositsConfigured: Bool {
        isConfigured && Env.usdtDepositsUrl != nil
    }

    func sendDestinations() async throws -> [UsdtDestination] {
        try beginOperation()
        defer { finishOperation() }
        let extra = try await wallet().orchestraDestinations()
        return Env.usdtDestinations + extra.filter { !Env.usdtDestinations.contains($0) }
    }

    func depositNetworks() async throws -> [UsdtDepositNetwork] {
        guard depositsConfigured else { return [] }
        return try await withDeposits { client, _, _ in try await client.networks() }
    }

    func prepareDeposit(network: UsdtDepositNetwork, amount: String) async throws -> UsdtDepositAddress {
        let value = try usdtParseAmount(value: amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
        return try await withDeposits { client, mnemonic, passphrase in
            try await client.receive(network: network, amount: value, mnemonic: mnemonic, passphrase: passphrase)
        }
    }

    func depositHistory(offset: UInt32) async throws -> UsdtDepositPage {
        try await withDeposits { client, mnemonic, passphrase in
            try await client.history(offset: offset, mnemonic: mnemonic, passphrase: passphrase)
        }
    }

    func depositDetail(id: String, offset: UInt32) async throws -> UsdtDepositDetail {
        try await withDeposits { client, mnemonic, passphrase in
            try await client.detail(depositId: id, offset: offset, mnemonic: mnemonic, passphrase: passphrase)
        }
    }

    func refundDeposit(_ deposit: UsdtDeposit, offset: UInt32, address: String) async throws {
        guard let network = UsdtDepositNetwork.named(deposit.network) else { throw UsdtError.DepositNeedsAttention }
        try await withDeposits { client, mnemonic, passphrase in
            try await client.requestRefund(depositId: deposit.id, offset: offset, refundAddress: address,
                                           network: network, mnemonic: mnemonic, passphrase: passphrase)
        }
    }

    private func withDeposits<T>(_ operation: @escaping @Sendable (UsdtDepositClient, String, String?) async throws -> T) async throws -> T {
        try beginOperation()
        defer { finishOperation() }
        guard depositsConfigured, let url = Env.usdtDepositsUrl else { throw UsdtError.NotConfigured }
        return try await ServiceQueue.background(.core, wrapErrors: false) {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else { throw UsdtError.InvalidCredentials }
            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0))
            let owner = try usdtAddress(mnemonic: mnemonic, passphrase: passphrase)
            let client = try UsdtDepositClient(address: owner, serviceUrl: url)
            return try await operation(client, mnemonic, passphrase)
        }
    }

    func wipe() async throws {
        if let wipeTask { return try await wipeTask.value }
        wiping = true
        let task = Task { try await performWipe() }
        wipeTask = task
        defer { wipeTask = nil }
        try await task.value
    }

    private func performWipe() async throws {
        if activeOperations > 0 {
            await withCheckedContinuation { idleWaiter = $0 }
        }
        core = nil
        credentialFingerprint = nil
        balance = nil
        address = ""
        receiveUri = ""
        transfers = []
        historyComplete = false
        errorMessage = nil
        let directory = storageDirectory
        try await ServiceQueue.background(.core, wrapErrors: false) {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("usdt-") &&
                ["sqlite", "sqlite-wal", "sqlite-shm"].contains(file.pathExtension)
            {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func beginOperation() throws {
        guard !wiping else { throw CancellationError() }
        activeOperations += 1
    }

    private func finishOperation() {
        activeOperations -= 1
        if activeOperations == 0 {
            idleWaiter?.resume()
            idleWaiter = nil
        }
    }

    private func wallet() async throws -> UsdtWallet {
        guard isConfigured, let bundlerUrl = Env.usdtBundlerUrl, let rpcUrl = Env.usdtRpcUrl else { throw UsdtError.NotConfigured }
        if let initialization { return try await initialization.value }
        let task = Task { try await initializeWallet(bundlerUrl: bundlerUrl, rpcUrl: rpcUrl) }
        initialization = task
        defer { initialization = nil }
        return try await task.value
    }

    private func initializeWallet(bundlerUrl: String, rpcUrl: String) async throws -> UsdtWallet {
        let credentials = try await ServiceQueue.background(.core, wrapErrors: false) {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else { throw UsdtError.InvalidCredentials }
            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0))
            return (mnemonic, passphrase)
        }
        let fingerprint = try SHA256.hash(data: JSONEncoder().encode([credentials.0, credentials.1 ?? ""]))
        if credentialFingerprint != fingerprint { core = nil; balance = nil; transfers = []; historyComplete = false }
        if let core { return core }
        let address = try await ServiceQueue.background(.core, wrapErrors: false) {
            try usdtAddress(mnemonic: credentials.0, passphrase: credentials.1)
        }
        let path = storageDirectory.appendingPathComponent("usdt-\(address).sqlite").path
        let wallet = try await ServiceQueue.background(.core, wrapErrors: false) {
            try UsdtWallet(
                address: address,
                storagePath: path,
                rpcUrl: rpcUrl,
                bundlerUrl: bundlerUrl,
                bridgeUrl: Env.usdtBridgesUrl,
                backup: UsdtVssBackup()
            )
        }
        credentialFingerprint = fingerprint
        self.address = wallet.receiveAddress()
        receiveUri = wallet.receiveUri()
        core = wallet
        return wallet
    }

    static func message(for error: Error) -> String {
        guard let error = error as? UsdtError else { return t("usdt__error_network") }
        switch error {
        case .NotConfigured: return t("usdt__error_configuration")
        case .InvalidAmount: return t("usdt__error_amount")
        case .InvalidAddress, .WrongNetwork: return t("usdt__error_address")
        case .InsufficientBalance: return t("usdt__error_balance")
        case .QuoteExpired: return t("usdt__error_expired")
        case .PendingTransfer: return t("usdt__error_pending")
        case .DepositNeedsAttention: return t("usdt__deposit_attention")
        case .DepositNotFound: return t("usdt__deposit_not_found")
        case .DepositAuthorizationRejected: return t("usdt__deposit_authorization")
        case let .DepositAmountOutOfRange(minUsdCents, maxUsdCents):
            let message = t("usdt__deposit_amount_out_of_range")
            guard minUsdCents != nil || maxUsdCents != nil else { return message }
            return t("usdt__deposit_limits") + ": " +
                (minUsdCents?.usdCents ?? "—") + " – " + (maxUsdCents?.usdCents ?? "—")
        case .UnsupportedRoute: return t("usdt__error_route")
        case .InvalidCredentials: return t("usdt__error_wallet")
        case .ClockSkew: return t("usdt__error_clock")
        case .UnsupportedDelegation: return t("usdt__error_delegation")
        case .BackupUnavailable: return t("usdt__error_backup")
        case .InvalidBackup: return t("usdt__error_storage")
        case .Storage: return t("usdt__error_storage")
        case .RateLimited: return t("usdt__error_rate_limit")
        case .LogRangeTooLarge: return t("usdt__error_response")
        case .InvalidPaymentProof, .InvalidResponse: return t("usdt__error_response")
        case .TransactionRejected: return t("usdt__error_rejected")
        case .NetworkUnavailable: return t("usdt__error_network")
        }
    }
}

extension UsdtDepositNetwork {
    static func named(_ value: String) -> Self? {
        switch value { case "solana": .solana
        case "polygon": .polygon
        case "bsc": .bsc
        case "base": .base
        case "tron": .tron; case "ethereum": .ethereum; default: nil }
    }
}

extension String {
    var usdCents: String {
        guard let value = UInt64(self) else { return "—" }
        return "$\((value / 100).formatted()).\(String(format: "%02d", value % 100))"
    }
}

private final class UsdtVssBackup: UsdtBackup, @unchecked Sendable {
    func persist(snapshot: String) async throws {
        do {
            try await BackupService.shared.persistWalletBackup(usdt: snapshot)
        } catch {
            throw UsdtError.BackupUnavailable
        }
    }
}
