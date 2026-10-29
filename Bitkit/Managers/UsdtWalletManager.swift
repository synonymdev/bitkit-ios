import BitkitCore
import Combine
import CryptoKit
import Foundation
import Observation

enum UsdtWalletError: Error {
    case selfSend
    case cannotDisable
}

@Observable @MainActor
final class UsdtWalletManager {
    private nonisolated(unsafe) static let backupStateChanged = PassthroughSubject<Void, Never>()
    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        backupStateChanged.eraseToAnyPublisher()
    }

    let receivedTxPublisher = PassthroughSubject<UsdtTransfer, Never>()
    private(set) var balance: UInt64? {
        didSet {
            balanceIsStale = balance == nil
            if let balance {
                displayBalanceCache.save(balance, address: address)
            }
        }
    }

    private(set) var balanceIsStale = true
    private(set) var cachedBalance: UInt64?
    private let displayBalanceCache: UsdtDisplayBalanceCache
    private(set) var address = ""
    private(set) var receiveUri = ""
    private(set) var transfers: [UsdtTransfer] = [] {
        didSet {
            if oldValue != transfers {
                Self.backupStateChanged.send()
            }
        }
    }

    private var pendingDepositIds: Set<String> = []
    private(set) var historyComplete = false
    private(set) var refreshing = false
    private(set) var recoveryGeneration = 0
    var errorMessage: String?
    var isSendPresented = false
    private var core: UsdtWallet?
    private var paymentEndpointCache: (fingerprint: SHA256.Digest, endpoint: PublicPaykitService.Endpoint)?
    private let storageDirectory: URL
    private let rpcUrl: String?
    private let bundlerUrl: String?
    private let loadCredentials: @MainActor () async throws -> (String, String?)
    private var wiping = false
    private var recoveryPaused = false
    private var activeOperations = 0
    private var initialization: Task<UsdtWallet, Error>?
    private var wipeTask: Task<Void, Error>?
    private var nextHistoryRefresh = Date.distantPast
    private var historyRefreshRequested = false
    private var nextRefresh = Date.distantPast
    private let now: () -> Date
    private var rateLimitedUntil = Date.distantPast
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var isConfigured: Bool {
        Env.isUsdtEnabled && rpcUrl != nil && bundlerUrl != nil
    }

    var hasStoredWallet: Bool {
        get throws {
            guard FileManager.default.fileExists(atPath: storageDirectory.path) else { return false }
            return try FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix("usdt-") && $0.pathExtension == "sqlite" }
        }
    }

    func shouldRefresh(enabled: Bool) -> Bool {
        enabled || hasProtectedFunds || (balance == nil && (try? hasStoredWallet) == true)
    }

    var hasProtectedFunds: Bool {
        UsdtPreference.protectsFunds(balance: balance, transfers: transfers) || !pendingDepositIds.isEmpty
    }

    var hasFundsOrPendingTransfers: Bool {
        UsdtPreference.hasFundsOrPendingTransfers(balance: balance, transfers: transfers) || !pendingDepositIds.isEmpty
    }

    func checkCanDisable() async throws {
        try beginOperation()
        defer { finishOperation() }
        guard !isSendPresented else { throw UsdtWalletError.cannotDisable }
        let wallet = try await wallet()
        balance = try await wallet.balance()
        transfers = try await wallet.refreshTransfers()
        guard !UsdtPreference.protectsFunds(balance: balance, transfers: transfers) else { throw UsdtWalletError.cannotDisable }
        if depositsConfigured {
            var offset: UInt32 = 0
            repeat {
                let page = try await depositHistory(offset: offset)
                for deposit in page.deposits where UsdtPreference.hasPendingDeposit(deposit.status) {
                    let detail = try await depositDetail(id: deposit.id, offset: offset)
                    guard !UsdtPreference.hasPendingDeposit(detail.order?.status ?? detail.deposit.status) else {
                        throw UsdtWalletError.cannotDisable
                    }
                }
                guard let next = page.nextOffset, next > offset else { break }
                offset = next
            } while true
        }
        guard !hasProtectedFunds else { throw UsdtWalletError.cannotDisable }
    }

    func recordDepositStatus(id: String, status: String) {
        guard !wiping else { return }
        if UsdtPreference.hasPendingDeposit(status) {
            pendingDepositIds.insert(id)
        } else {
            pendingDepositIds.remove(id)
        }
    }

    var networkName: String {
        "Arbitrum One"
    }

    init(
        storageDirectory: URL = Env.bitkitCoreStorage(walletIndex: 0),
        rpcUrl: String? = Env.usdtRpcUrl,
        bundlerUrl: String? = Env.usdtBundlerUrl,
        now: @escaping () -> Date = Date.init,
        core: UsdtWallet? = nil,
        defaults: UserDefaults = .standard,
        loadCredentials: @escaping @MainActor () async throws -> (String, String?) = {
            try await ServiceQueue.background(.core, wrapErrors: false) {
                guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else { throw UsdtError.InvalidCredentials }
                return try (mnemonic, Keychain.loadString(key: .bip39Passphrase(index: 0)))
            }
        }
    ) {
        self.now = now
        self.core = core
        displayBalanceCache = UsdtDisplayBalanceCache(storageDirectory: storageDirectory, rpcUrl: rpcUrl,
                                                      bundlerUrl: bundlerUrl, defaults: defaults)
        self.storageDirectory = storageDirectory
        self.rpcUrl = rpcUrl
        self.bundlerUrl = bundlerUrl
        self.loadCredentials = loadCredentials
    }

    func loadCachedBalance() async {
        guard !wiping else { return }
        do {
            let endpoint = try await paymentEndpoint()
            try Task.checkCancellation()
            guard !wiping else { return }
            cachedBalance = displayBalanceCache.balance(for: endpoint.value)
        } catch is CancellationError {
        } catch {
            cachedBalance = nil
        }
    }

    func refresh(includeHistory: Bool = false) async {
        guard isConfigured, !wiping else { return }
        historyRefreshRequested = historyRefreshRequested || includeHistory
        guard !refreshing, now() >= rateLimitedUntil else { return }
        let historyDue = historyRefreshRequested && !isSendPresented && Date() >= nextHistoryRefresh
        guard historyDue || Date() >= nextRefresh else { return }
        var refreshDelay: TimeInterval = 10
        activeOperations += 1
        refreshing = true
        balanceIsStale = true
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
                if let error = error as? UsdtError, case .RateLimited = error {
                    throw error
                }
                settlementError = error
            }
            try Task.checkCancellation()
            if historyRefreshRequested, !isSendPresented, Date() >= nextHistoryRefresh {
                historyRefreshRequested = false
                nextHistoryRefresh = Date().addingTimeInterval(10)
                let complete = try await wallet.syncHistory()
                historyComplete = historyComplete || complete
                transfers = try await ServiceQueue.background(.core, wrapErrors: false) { try wallet.history() }
                for transfer in Self.newIncomingTransfers(previous: previousTransfers, current: transfers) {
                    receivedTxPublisher.send(transfer)
                }
            }
            if let settlementError {
                throw settlementError
            }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if let error = error as? UsdtError, case .RateLimited = error {
                refreshDelay = 60; rateLimitedUntil = now().addingTimeInterval(60)
            }
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
        return try await withRateLimit {
            let value = try usdtParseAmount(value: amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
            let wallet = try await wallet()
            if recipient.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wallet.receiveAddress()) == .orderedSame {
                throw UsdtWalletError.selfSend
            }
            return try await wallet.quoteTransfer(recipient: recipient, amount: value, destination: destination)
        }
    }

    func quoteMaximum(recipient: String, destination: UsdtDestination) async throws -> UsdtQuote {
        try beginOperation()
        defer { finishOperation() }
        return try await withRateLimit {
            let wallet = try await wallet()
            if recipient.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wallet.receiveAddress()) == .orderedSame {
                throw UsdtWalletError.selfSend
            }
            return try await wallet.quoteMaxTransfer(recipient: recipient, destination: destination)
        }
    }

    func backupSnapshot() async throws -> String? {
        guard try hasStoredWallet else { return nil }
        try beginOperation(requiresNetwork: false)
        defer { finishOperation() }
        let wallet = try await wallet(requiresNetwork: false)
        return try await ServiceQueue.background(.core, wrapErrors: false) { try wallet.exportBackup() }
    }

    func restoreBackup(_ snapshot: String) async throws {
        try beginOperation(requiresNetwork: false)
        defer { finishOperation() }
        let wallet = try await wallet(requiresNetwork: false)
        try await wallet.restoreBackup(snapshot: snapshot)
        displayBalanceCache.clear()
        cachedBalance = nil
        balance = nil
        pendingDepositIds.removeAll()
        transfers = try wallet.history()
        historyComplete = false
    }

    func paymentEndpoint() async throws -> PublicPaykitService.Endpoint {
        try beginOperation()
        defer { finishOperation() }
        let credentials = try await loadCredentials()
        try Task.checkCancellation()
        let fingerprint = SHA256.hash(data: Data("\(credentials.0.utf8.count):\(credentials.0)\(credentials.1 ?? "")".utf8))
        if let cached = paymentEndpointCache, cached.fingerprint == fingerprint {
            return cached.endpoint
        }
        paymentEndpointCache = nil
        let endpoint = try await ServiceQueue.background(.core, wrapErrors: false) {
            try PaykitUsdt.endpoint(address: usdtAddress(mnemonic: credentials.0, passphrase: credentials.1))
        }
        try Task.checkCancellation()
        paymentEndpointCache = (fingerprint, endpoint)
        return endpoint
    }

    func send(_ quote: UsdtQuote, submissionDeadline: PaykitPreciseInstant? = nil,
              beforeSubmission: @escaping @MainActor () async throws -> Void = {}) async throws
    {
        try beginOperation()
        defer { finishOperation() }
        return try await withRateLimit {
            let wallet = try await wallet()
            let credentials = try await loadCredentials()
            do {
                let transfer = try await ServiceQueue.background(.core, wrapErrors: false) {
                    try await beforeSubmission()
                    return try await wallet.sendWithDeadline(
                        quoteId: quote.id, mnemonic: credentials.0, passphrase: credentials.1,
                        submissionDeadline: submissionDeadline?.timestamp
                    )
                }
                transfers.removeAll { $0.id == transfer.id }
                transfers.insert(transfer, at: 0)
            } catch {
                if let saved = try? await ServiceQueue.background(.core, wrapErrors: false, { try wallet.history() }) {
                    transfers = saved
                }
                throw error
            }
        }
    }

    func paymentProof(quoteId: String, binding: UsdtPaymentProofBinding) async throws -> UsdtPaymentProof? {
        try beginOperation()
        defer { finishOperation() }
        let core = try await wallet()
        let credentials = try await loadCredentials()
        return try await core.createPaymentProof(transferId: quoteId, binding: binding, mnemonic: credentials.0, passphrase: credentials.1)
    }

    func storedTransfer(_ id: String) async throws -> UsdtTransfer? {
        try beginOperation()
        defer { finishOperation() }
        let core = try await wallet()
        return try await ServiceQueue.background(.core, wrapErrors: false) { try core.history().first { $0.id == id } }
    }

    func retryTransfer(_ id: String) async throws {
        try beginOperation()
        defer { finishOperation() }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        try await withRateLimit {
            let wallet = try await wallet()
            guard let transfer = try wallet.history().first(where: { $0.id == id }) else { throw UsdtError.InvalidBackup }
            guard transfer.status == .pending else { return }
            transfers = try await wallet.refreshTransfers()
        }
    }

    func verifyPayment(binding: UsdtPaymentProofBinding, proof: UsdtPaymentProof) async throws -> UsdtVerifiedPayment? {
        try beginOperation()
        defer { finishOperation() }
        return try await wallet().verifyPaymentProof(binding: binding, proof: proof)
    }

    func waitForTransfer(_ id: String) async {
        guard isConfigured, !wiping, !refreshing, !Task.isCancelled, now() >= rateLimitedUntil else { return }
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
                if transfer.status != .pending {
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
        } catch {
            if let error = error as? UsdtError, case .RateLimited = error {
                rateLimitedUntil = now().addingTimeInterval(60)
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
        let page = try await withDeposits { client, mnemonic, passphrase in
            try await client.history(offset: offset, mnemonic: mnemonic, passphrase: passphrase)
        }
        for deposit in page.deposits {
            recordDepositStatus(id: deposit.id, status: deposit.status)
        }
        return page
    }

    func depositDetail(id: String, offset: UInt32) async throws -> UsdtDepositDetail {
        let detail = try await withDeposits { client, mnemonic, passphrase in
            try await client.detail(depositId: id, offset: offset, mnemonic: mnemonic, passphrase: passphrase)
        }
        recordDepositStatus(id: id, status: detail.order?.status ?? detail.deposit.status)
        return detail
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
        let credentials = try await loadCredentials()
        return try await ServiceQueue.background(.core, wrapErrors: false) {
            let owner = try usdtAddress(mnemonic: credentials.0, passphrase: credentials.1)
            let client = try UsdtDepositClient(address: owner, serviceUrl: url)
            return try await operation(client, credentials.0, credentials.1)
        }
    }

    func wipe() async throws {
        if let wipeTask {
            return try await wipeTask.value
        }
        wiping = true
        let task = Task { try await performWipe() }
        wipeTask = task
        defer { wipeTask = nil }
        try await task.value
    }

    var canRecoverTransfers: Bool {
        !recoveryPaused && !UsdtRecoveryRestoreGate.isPending
    }

    func pauseForRecoveryRestore() async {
        recoveryPaused = true
        PaykitUsdtPaymentService.shared.pauseForRecoveryRestore()
        if activeOperations > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    func resumeAfterRecoveryRestore() {
        recoveryPaused = false
    }

    private func performWipe() async throws {
        if activeOperations > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        core = nil
        recoveryPaused = false
        paymentEndpointCache = nil
        displayBalanceCache.clear()
        cachedBalance = nil
        balance = nil
        address = ""
        receiveUri = ""
        transfers = []
        pendingDepositIds.removeAll()
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

    private func withRateLimit<T>(_ operation: () async throws -> T) async throws -> T {
        guard now() >= rateLimitedUntil else { throw UsdtError.RateLimited }
        do { return try await operation() }
        catch {
            if let error = error as? UsdtError, case .RateLimited = error {
                rateLimitedUntil = now().addingTimeInterval(60)
            }
            throw error
        }
    }

    private func beginOperation(requiresNetwork: Bool = true) throws {
        guard !wiping else { throw CancellationError() }
        guard !requiresNetwork || canRecoverTransfers else { throw UsdtError.BackupUnavailable }
        activeOperations += 1
    }

    private func finishOperation() {
        activeOperations -= 1
        if activeOperations == 0 {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func wallet(requiresNetwork: Bool = true) async throws -> UsdtWallet {
        guard !requiresNetwork || canRecoverTransfers else { throw UsdtError.BackupUnavailable }
        if requiresNetwork, !isConfigured {
            throw UsdtError.NotConfigured
        }
        if let core {
            return core
        }
        if let initialization {
            return try await initialization.value
        }
        // Core's constructor requires URLs even for local export/restore. Network operations remain configuration-gated.
        let task = Task {
            try await initializeWallet(bundlerUrl: bundlerUrl ?? "http://127.0.0.1:1", rpcUrl: rpcUrl ?? "http://127.0.0.1:1")
        }
        initialization = task
        defer { initialization = nil }
        return try await task.value
    }

    private func initializeWallet(bundlerUrl: String, rpcUrl: String) async throws -> UsdtWallet {
        let credentials = try await loadCredentials()
        let address = try await ServiceQueue.background(.core, wrapErrors: false) {
            try usdtAddress(mnemonic: credentials.0, passphrase: credentials.1)
        }
        let path = storageDirectory.appendingPathComponent("usdt-\(address).sqlite").path
        let backup = UsdtVssBackup { [weak self] in self?.recoveryGeneration &+= 1 }
        let wallet = try await ServiceQueue.background(.core, wrapErrors: false) {
            try UsdtWallet(
                address: address,
                storagePath: path,
                rpcUrl: rpcUrl,
                bundlerUrl: bundlerUrl,
                bridgeUrl: Env.usdtBridgesUrl,
                backup: backup
            )
        }
        self.address = wallet.receiveAddress()
        cachedBalance = displayBalanceCache.balance(for: self.address)
        receiveUri = wallet.receiveUri()
        core = wallet
        return wallet
    }

    static func message(for error: Error) -> String {
        if let error = error as? UsdtWalletError {
            return t(error == .selfSend ? "usdt__error_self_send" : "usdt__disable_unavailable")
        }
        guard let error = error as? UsdtError else { return t("usdt__error_network") }
        switch error {
        case .NotConfigured: return t("usdt__error_configuration")
        case .InvalidAmount: return t("usdt__error_amount")
        case .BridgeAmountTooSmall: return t("usdt__error_bridge_amount")
        case let .BridgeAmountBelowMinimum(minUsdCents):
            return minUsdCents.map { t("usdt__deposit_minimum", variables: ["amount": $0.usdCents]) }
                ?? t("usdt__error_bridge_minimum")
        case let .BridgeAmountAboveMaximum(maxUsdCents):
            return maxUsdCents.map { t("usdt__deposit_maximum", variables: ["amount": $0.usdCents]) }
                ?? t("usdt__error_bridge_maximum")
        case .BridgeLiquidityUnavailable: return t("usdt__error_bridge_liquidity")
        case .InvalidAddress, .WrongNetwork: return t("usdt__error_address")
        case .InsufficientBalance: return t("usdt__error_balance")
        case .QuoteExpired: return t("usdt__error_expired")
        case .SubmissionDeadlineExpired: return t("wallet__payment_request_expired")
        case .InvalidSubmissionDeadline: return t("wallet__payment_request_unavailable")
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
        case let .TransactionRejected(reason):
            return t(reason == "Paymaster fee collection failed" ? "usdt__error_fee_collection" : "usdt__error_rejected")
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
        formattedUsdCents()
    }

    func formattedUsdCents(locale: Locale = .current) -> String {
        guard let value = UInt64(self) else { return "—" }
        return "$" + usdDisplayAmount(value, locale: locale)
    }
}

final class UsdtVssBackup: UsdtBackup, @unchecked Sendable {
    private let persistSnapshot: @Sendable (String) async throws -> Void
    private let onAcknowledged: @MainActor @Sendable () -> Void

    init(persistSnapshot: @escaping @Sendable (String) async throws -> Void = {
        try await BackupService.shared.persistUsdtRecoveryBackup(snapshot: $0)
    }, onAcknowledged: @escaping @MainActor @Sendable () -> Void) {
        self.persistSnapshot = persistSnapshot
        self.onAcknowledged = onAcknowledged
    }

    func persist(snapshot: String) async throws {
        do {
            try await persistSnapshot(snapshot)
            await onAcknowledged()
        } catch {
            Logger.error(PaykitResolutionFailureDiagnostics.reason(for: error), context: "USDT recovery backup failed")
            throw UsdtError.BackupUnavailable
        }
    }
}
