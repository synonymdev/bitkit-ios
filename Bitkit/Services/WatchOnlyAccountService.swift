import BitkitCore
import Combine
import CryptoKit
import Foundation
import LDKNode

enum WatchOnlyAccountSetupState: String, Codable {
    case pendingDelivery
    case authorizing
    case active
}

struct WatchOnlyAccountRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let walletIndex: Int
    let accountIndex: UInt32
    let addressType: String
    let xpub: String
    let requestFingerprint: String
    let createdAt: UInt64
    var name: String
    var isTrackingEnabled: Bool
    var setupState: WatchOnlyAccountSetupState

    var derivationPath: String {
        let coinType = Env.network == .bitcoin ? "0" : "1"
        return "m/84'/\(coinType)'/\(accountIndex)'"
    }
}

struct WatchOnlyAccountAuthorizationAttempt: Equatable {
    let accountId: UUID
    fileprivate let token = UUID()
}

enum WatchOnlyAccountError: LocalizedError, Equatable {
    case authorizationAccountMissing
    case authorizationInProgress
    case invalidAccountName
    case invalidExtendedPublicKey

    var errorDescription: String? {
        switch self {
        case .authorizationAccountMissing, .authorizationInProgress:
            t("watch_only_accounts__setup_not_finished")
        case .invalidAccountName:
            t("pubky_auth__watch_only_account_name_error")
        case .invalidExtendedPublicKey:
            t("pubky_auth__watch_only_account_xpub_error")
        }
    }
}

protocol WatchOnlyAccountNodeHandling: AnyObject {
    var currentWalletIndex: Int { get }
    func exportWatchOnlyAccountXpub(accountIndex: UInt32, addressType: LDKNode.AddressType) async throws -> String
    func setWatchOnlyAccountTracking(accountIndex: UInt32, addressType: LDKNode.AddressType, xpub: String, enabled: Bool) async throws
    #if !BITKIT_NOTIFICATION_EXTENSION
        func reconcileWatchOnlyAccountTracking(
            records: [WatchOnlyAccountRecord],
            managedRecords: [WatchOnlyAccountRecord]
        ) async throws
    #endif
}

extension LightningService: WatchOnlyAccountNodeHandling {}

struct WatchOnlyAccountAllocationState: Codable, Equatable {
    var highestAccountIndexByWallet: [String: UInt32] = [:]
    var pendingAccountIndexByRequest: [String: UInt32] = [:]
}

private struct WatchOnlyAccountData: Codable {
    var accounts: [WatchOnlyAccountRecord] = []
    var allocationState = WatchOnlyAccountAllocationState()
    var accountsPendingUnload: [WatchOnlyAccountRecord] = []
}

struct WatchOnlyAccountBackupSnapshot {
    let accounts: [WatchOnlyAccountRecord]
    let allocationState: WatchOnlyAccountAllocationState
}

struct WatchOnlyAccountReconciliationSnapshot {
    let accounts: [WatchOnlyAccountRecord]
    let managedAccounts: [WatchOnlyAccountRecord]
}

enum WatchOnlyAccountStore {
    static let walletBackupDataChangedPublisher = walletBackupDataChangedSubject.eraseToAnyPublisher()

    static let dataKey = "watchOnlyAccountDataV1"

    private static let maximumAccountIndex = UInt32(Int32.max)
    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    static func load(defaults: UserDefaults = .standard) throws -> [WatchOnlyAccountRecord] {
        try loadData(defaults: defaults).accounts.sorted { $0.accountIndex < $1.accountIndex }
    }

    static func enabledAccounts(for walletIndex: Int, defaults: UserDefaults = .standard) throws -> [WatchOnlyAccountRecord] {
        try load(defaults: defaults).filter {
            $0.walletIndex == walletIndex
                && ($0.setupState == .active || $0.setupState == .authorizing)
                && $0.isTrackingEnabled
        }
    }

    static func save(_ records: [WatchOnlyAccountRecord], defaults: UserDefaults = .standard) throws {
        var data = try loadData(defaults: defaults)
        data.accounts = records.sorted { $0.accountIndex < $1.accountIndex }
        data.allocationState.reconcileAccountIndexes(records)
        try saveData(data, defaults: defaults)
    }

    static func backupSnapshot(defaults: UserDefaults = .standard) throws -> WatchOnlyAccountBackupSnapshot {
        let data = try loadData(defaults: defaults)
        return WatchOnlyAccountBackupSnapshot(
            accounts: data.accounts.sorted { $0.accountIndex < $1.accountIndex },
            allocationState: data.allocationState
        )
    }

    static func restore(
        _ records: [WatchOnlyAccountRecord]?,
        allocationState restoredAllocationState: WatchOnlyAccountAllocationState? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        let restoredInput = records ?? []
        let restoredAccounts = sanitizedAccounts(restoredInput)
        var data = (try? loadData(defaults: defaults)) ?? WatchOnlyAccountData()
        let currentAccounts = data.accounts
        let locallyManagedAccounts = uniqueAccounts(currentAccounts + data.accountsPendingUnload)

        let protectedLocalAccounts = sanitizedAccounts(locallyManagedAccounts.filter { localAccount in
            localAccount.setupState == .authorizing
                || shouldPreserveLocalAccount(localAccount, from: restoredAccounts)
        })
        let mergedAccounts = sanitizedAccounts(protectedLocalAccounts + restoredAccounts)
        let mergedManagementKeys = Set(mergedAccounts.map(managementKey))

        data.accountsPendingUnload = uniqueAccounts(currentAccounts + data.accountsPendingUnload)
            .filter { !mergedManagementKeys.contains(managementKey($0)) }
        data.accounts = mergedAccounts

        var localAllocationState = WatchOnlyAccountAllocationState(
            highestAccountIndexByWallet: validHighestAccountIndexes(data.allocationState.highestAccountIndexByWallet),
            pendingAccountIndexByRequest: validPendingAccountIndexes(data.allocationState.pendingAccountIndexByRequest)
        )
        localAllocationState.reconcileAccountIndexes(locallyManagedAccounts)
        localAllocationState.raiseHighWaterMarksForPendingReservations()

        var highestAccountIndexByWallet = localAllocationState.highestAccountIndexByWallet
        for (walletKey, restoredIndex) in validHighestAccountIndexes(
            restoredAllocationState?.highestAccountIndexByWallet ?? [:]
        ) {
            highestAccountIndexByWallet[walletKey] = max(
                highestAccountIndexByWallet[walletKey] ?? 0,
                restoredIndex
            )
        }

        var allocationState = WatchOnlyAccountAllocationState(
            highestAccountIndexByWallet: highestAccountIndexByWallet,
            pendingAccountIndexByRequest: [:]
        )
        allocationState.reconcileAccountIndexes(locallyManagedAccounts + restoredInput + data.accountsPendingUnload)

        let retainedLocalPendingReservations = restoredAllocationState == nil
            ? [:]
            : localAllocationState.pendingAccountIndexByRequest
        allocationState.pendingAccountIndexByRequest = mergedPendingAccountIndexes(
            accounts: mergedAccounts,
            blockedAccounts: data.accountsPendingUnload,
            localPendingAccountIndexes: retainedLocalPendingReservations,
            restoredPendingAccountIndexes: restoredAllocationState?.pendingAccountIndexByRequest ?? [:],
            localHighestAccountIndexByWallet: localAllocationState.highestAccountIndexByWallet
        )
        allocationState.raiseHighWaterMarksForPendingReservations()

        data.allocationState = allocationState
        try saveData(data, defaults: defaults)
    }

    static func reconciliationSnapshot(defaults: UserDefaults = .standard) throws -> WatchOnlyAccountReconciliationSnapshot {
        let data = try loadData(defaults: defaults)
        return WatchOnlyAccountReconciliationSnapshot(
            accounts: data.accounts.sorted { $0.accountIndex < $1.accountIndex },
            managedAccounts: uniqueAccounts(data.accounts + data.accountsPendingUnload)
        )
    }

    static func finishReconciliation(walletIndex: Int, defaults: UserDefaults = .standard) throws {
        var data = try loadData(defaults: defaults)
        guard data.accountsPendingUnload.contains(where: { $0.walletIndex == walletIndex }) else { return }
        data.accountsPendingUnload = data.accountsPendingUnload.filter { $0.walletIndex != walletIndex }
        try saveData(data, defaults: defaults)
    }

    static func reserveAccountIndex(walletIndex: Int, requestFingerprint: String, defaults: UserDefaults = .standard) throws -> UInt32 {
        var data = try loadData(defaults: defaults)
        data.allocationState.highestAccountIndexByWallet = data.allocationState.highestAccountIndexByWallet.filter {
            isValidAccountIndex($0.value)
        }
        data.allocationState.pendingAccountIndexByRequest = data.allocationState.pendingAccountIndexByRequest.filter {
            isValidAccountIndex($0.value)
        }
        let requestKey = allocationRequestKey(walletIndex: walletIndex, requestFingerprint: requestFingerprint)
        if let pendingAccountIndex = data.allocationState.pendingAccountIndexByRequest[requestKey] {
            return pendingAccountIndex
        }

        let walletKey = String(walletIndex)
        let highestPersistedAccountIndex = data.accounts
            .filter { $0.walletIndex == walletIndex && isValidAccountIndex($0.accountIndex) }
            .map(\.accountIndex)
            .max() ?? 0
        let highestAccountIndex = max(
            data.allocationState.highestAccountIndexByWallet[walletKey] ?? 0,
            highestPersistedAccountIndex
        )
        guard highestAccountIndex < maximumAccountIndex else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }

        let accountIndex = highestAccountIndex + 1
        data.allocationState.highestAccountIndexByWallet[walletKey] = accountIndex
        data.allocationState.pendingAccountIndexByRequest[requestKey] = accountIndex
        try saveData(data, defaults: defaults)
        return accountIndex
    }

    static func markSetupActive(id: UUID, defaults: UserDefaults = .standard) throws -> [WatchOnlyAccountRecord] {
        var data = try loadData(defaults: defaults)
        guard let index = data.accounts.firstIndex(where: { $0.id == id }) else {
            throw WatchOnlyAccountError.authorizationAccountMissing
        }

        data.accounts[index].setupState = .active
        data.accounts[index].isTrackingEnabled = true
        let record = data.accounts[index]
        data.allocationState.pendingAccountIndexByRequest.removeValue(
            forKey: allocationRequestKey(walletIndex: record.walletIndex, requestFingerprint: record.requestFingerprint)
        )
        try saveData(data, defaults: defaults)
        return data.accounts.sorted { $0.accountIndex < $1.accountIndex }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dataKey)
    }

    private static func loadData(defaults: UserDefaults) throws -> WatchOnlyAccountData {
        guard let encoded = defaults.data(forKey: dataKey) else { return WatchOnlyAccountData() }
        return try JSONDecoder().decode(WatchOnlyAccountData.self, from: encoded)
    }

    private static func saveData(_ data: WatchOnlyAccountData, defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(data), forKey: dataKey)
        walletBackupDataChangedSubject.send()
    }

    private static func allocationRequestKey(walletIndex: Int, requestFingerprint: String) -> String {
        "\(walletIndex):\(requestFingerprint)"
    }

    private static func walletIndex(fromAllocationRequestKey requestKey: String) -> Int? {
        guard let separatorIndex = requestKey.firstIndex(of: ":"),
              separatorIndex != requestKey.startIndex,
              requestKey.index(after: separatorIndex) != requestKey.endIndex,
              let walletIndex = Int(requestKey[..<separatorIndex]),
              walletIndex >= 0
        else { return nil }
        return walletIndex
    }

    private static func allocationSlotKey(walletIndex: Int, accountIndex: UInt32) -> String {
        "\(walletIndex):\(accountIndex)"
    }

    private static func isValidAccountIndex(_ accountIndex: UInt32) -> Bool {
        accountIndex > 0 && accountIndex <= maximumAccountIndex
    }

    private static func validHighestAccountIndexes(_ indexes: [String: UInt32]) -> [String: UInt32] {
        indexes.reduce(into: [:]) { result, entry in
            guard let walletIndex = Int(entry.key),
                  walletIndex >= 0,
                  isValidAccountIndex(entry.value)
            else { return }
            let walletKey = String(walletIndex)
            result[walletKey] = max(result[walletKey] ?? 0, entry.value)
        }
    }

    private static func validPendingAccountIndexes(_ indexes: [String: UInt32]) -> [String: UInt32] {
        indexes.filter {
            isValidAccountIndex($0.value) && walletIndex(fromAllocationRequestKey: $0.key) != nil
        }
    }

    private static func mergedPendingAccountIndexes(
        accounts: [WatchOnlyAccountRecord],
        blockedAccounts: [WatchOnlyAccountRecord],
        localPendingAccountIndexes: [String: UInt32],
        restoredPendingAccountIndexes: [String: UInt32],
        localHighestAccountIndexByWallet: [String: UInt32]
    ) -> [String: UInt32] {
        let activeSlots = Set(accounts.filter { $0.setupState == .active }.map {
            allocationSlotKey(walletIndex: $0.walletIndex, accountIndex: $0.accountIndex)
        })
        let blockedSlots = Set(blockedAccounts.map {
            allocationSlotKey(walletIndex: $0.walletIndex, accountIndex: $0.accountIndex)
        })
        var pendingAccountIndexes: [String: UInt32] = [:]
        var reservedSlots = Set<String>()

        func reserve(requestKey: String, accountIndex: UInt32, allowsHistoricalIndex: Bool) {
            guard pendingAccountIndexes[requestKey] == nil,
                  isValidAccountIndex(accountIndex),
                  let walletIndex = walletIndex(fromAllocationRequestKey: requestKey)
            else { return }
            let slot = allocationSlotKey(walletIndex: walletIndex, accountIndex: accountIndex)
            guard !reservedSlots.contains(slot),
                  !activeSlots.contains(slot),
                  !blockedSlots.contains(slot),
                  allowsHistoricalIndex || accountIndex > (localHighestAccountIndexByWallet[String(walletIndex)] ?? 0)
            else { return }
            pendingAccountIndexes[requestKey] = accountIndex
            reservedSlots.insert(slot)
        }

        for account in accounts where account.setupState != .active {
            reserve(
                requestKey: allocationRequestKey(
                    walletIndex: account.walletIndex,
                    requestFingerprint: account.requestFingerprint
                ),
                accountIndex: account.accountIndex,
                allowsHistoricalIndex: true
            )
        }
        for (requestKey, accountIndex) in localPendingAccountIndexes.sorted(by: { $0.key < $1.key }) {
            reserve(requestKey: requestKey, accountIndex: accountIndex, allowsHistoricalIndex: true)
        }
        for (requestKey, accountIndex) in restoredPendingAccountIndexes.sorted(by: { $0.key < $1.key }) {
            reserve(requestKey: requestKey, accountIndex: accountIndex, allowsHistoricalIndex: false)
        }

        return pendingAccountIndexes
    }

    private static func sanitizedAccounts(_ accounts: [WatchOnlyAccountRecord]) -> [WatchOnlyAccountRecord] {
        var ids = Set<UUID>()
        var managementKeys = Set<String>()
        var incompleteRequestKeys = Set<String>()
        var sanitized: [WatchOnlyAccountRecord] = []

        for input in accounts where isUsableAccount(input) {
            let account = normalizedTrackingState(input)
            let accountManagementKey = managementKey(account)
            let requestKey = allocationRequestKey(
                walletIndex: account.walletIndex,
                requestFingerprint: account.requestFingerprint
            )
            guard !ids.contains(account.id),
                  !managementKeys.contains(accountManagementKey),
                  account.setupState == .active || !incompleteRequestKeys.contains(requestKey)
            else { continue }
            ids.insert(account.id)
            managementKeys.insert(accountManagementKey)
            if account.setupState != .active {
                incompleteRequestKeys.insert(requestKey)
            }
            sanitized.append(account)
        }

        return sanitized.sorted {
            ($0.walletIndex, $0.accountIndex, $0.createdAt) < ($1.walletIndex, $1.accountIndex, $1.createdAt)
        }
    }

    private static func uniqueAccounts(_ accounts: [WatchOnlyAccountRecord]) -> [WatchOnlyAccountRecord] {
        var managementKeys = Set<String>()
        return accounts.filter { managementKeys.insert(managementKey($0)).inserted }.sorted {
            ($0.walletIndex, $0.accountIndex) < ($1.walletIndex, $1.accountIndex)
        }
    }

    private static func isUsableAccount(_ account: WatchOnlyAccountRecord) -> Bool {
        account.walletIndex >= 0
            && isValidAccountIndex(account.accountIndex)
            && account.addressType == LDKNode.AddressType.nativeSegwit.stringValue
            && (try? WatchOnlyAccountClaimCodec.serializedXpub(account.xpub)) != nil
    }

    private static func normalizedTrackingState(_ account: WatchOnlyAccountRecord) -> WatchOnlyAccountRecord {
        var account = account
        switch account.setupState {
        case .pendingDelivery:
            account.isTrackingEnabled = false
        case .authorizing:
            account.isTrackingEnabled = true
        case .active:
            break
        }
        return account
    }

    private static func shouldPreserveLocalAccount(
        _ localAccount: WatchOnlyAccountRecord,
        from restoredAccounts: [WatchOnlyAccountRecord]
    ) -> Bool {
        let conflicts = restoredAccounts.filter {
            $0.id == localAccount.id || managementKey($0) == managementKey(localAccount)
        }
        guard !conflicts.isEmpty else { return false }
        if conflicts.contains(where: { !hasSameOwner(localAccount, $0) }) {
            return true
        }
        return localAccount.setupState == .active
            && conflicts.allSatisfy { $0.setupState != .active }
    }

    private static func hasSameOwner(_ lhs: WatchOnlyAccountRecord, _ rhs: WatchOnlyAccountRecord) -> Bool {
        managementKey(lhs) == managementKey(rhs)
            && lhs.requestFingerprint == rhs.requestFingerprint
            && lhs.xpub == rhs.xpub
    }

    private static func managementKey(_ account: WatchOnlyAccountRecord) -> String {
        "\(account.walletIndex):\(account.addressType):\(account.accountIndex)"
    }
}

private extension WatchOnlyAccountAllocationState {
    mutating func reconcileAccountIndexes(_ accounts: [WatchOnlyAccountRecord]) {
        let validWalletAccounts = accounts.filter { $0.walletIndex >= 0 }
        for (walletIndex, walletAccounts) in Dictionary(grouping: validWalletAccounts, by: \WatchOnlyAccountRecord.walletIndex) {
            guard let accountIndex = walletAccounts.map(\.accountIndex).filter({
                $0 > 0 && $0 <= UInt32(Int32.max)
            }).max() else { continue }
            let walletKey = String(walletIndex)
            highestAccountIndexByWallet[walletKey] = max(highestAccountIndexByWallet[walletKey] ?? 0, accountIndex)
        }
    }

    mutating func raiseHighWaterMarksForPendingReservations() {
        for (requestKey, accountIndex) in pendingAccountIndexByRequest {
            guard let separatorIndex = requestKey.firstIndex(of: ":"),
                  let walletIndex = Int(requestKey[..<separatorIndex]),
                  walletIndex >= 0,
                  accountIndex > 0,
                  accountIndex <= UInt32(Int32.max)
            else { continue }
            let walletKey = String(walletIndex)
            highestAccountIndexByWallet[walletKey] = max(highestAccountIndexByWallet[walletKey] ?? 0, accountIndex)
        }
    }
}

final class WatchOnlyAccountLifecycleCoordinator: @unchecked Sendable {
    static let shared = WatchOnlyAccountLifecycleCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let stateLock = NSLock()
    private let onWaiterQueued: (@Sendable () -> Void)?
    private var isLocked = false
    private var waiters: [Waiter] = []

    init(onWaiterQueued: (@Sendable () -> Void)? = nil) {
        self.onWaiterQueued = onWaiterQueued
    }

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stateLock.lock()
                if Task.isCancelled {
                    stateLock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if isLocked {
                    waiters.append(Waiter(id: waiterId, continuation: continuation))
                    stateLock.unlock()
                    onWaiterQueued?()
                } else {
                    isLocked = true
                    stateLock.unlock()
                    continuation.resume()
                }
            }
        } onCancel: {
            cancelWaiter(id: waiterId)
        }
    }

    private func cancelWaiter(id: UUID) {
        stateLock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            stateLock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        stateLock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        stateLock.lock()
        if waiters.isEmpty {
            isLocked = false
            stateLock.unlock()
        } else {
            let next = waiters.removeFirst()
            stateLock.unlock()
            next.continuation.resume()
        }
    }
}

@Observable
@MainActor
final class WatchOnlyAccountManager {
    static let shared = WatchOnlyAccountManager()
    private static let companionClaimQueryParameter = "x-bitkit-claim"

    private(set) var accounts: [WatchOnlyAccountRecord]

    private let defaults: UserDefaults
    private let lifecycleCoordinator: WatchOnlyAccountLifecycleCoordinator
    private let node: WatchOnlyAccountNodeHandling
    private var activeAuthorizationAttempt: WatchOnlyAccountAuthorizationAttempt?
    private var preservesAuthorizingStateOnFailure = false

    init(
        defaults: UserDefaults = .standard,
        lifecycleCoordinator: WatchOnlyAccountLifecycleCoordinator = .shared,
        node: WatchOnlyAccountNodeHandling = LightningService.shared
    ) {
        self.defaults = defaults
        self.lifecycleCoordinator = lifecycleCoordinator
        self.node = node
        do {
            accounts = try WatchOnlyAccountStore.load(defaults: defaults)
        } catch {
            accounts = []
            Logger.error("Failed to load watch-only account state: \(error)", context: "WatchOnlyAccountManager")
        }
    }

    func accounts(for walletIndex: Int) -> [WatchOnlyAccountRecord] {
        accounts.filter { $0.walletIndex == walletIndex }
    }

    func prepareUnsignedClaim(authUrl: String, name: String) async throws -> (WatchOnlyAccountRecord, Data) {
        let normalizedName = try Self.normalizedName(name)
        let fingerprint = Self.requestFingerprint(authUrl)
        return try await prepareUnsignedClaim(
            normalizedName: normalizedName,
            fingerprint: fingerprint,
            walletIndex: node.currentWalletIndex
        )
    }

    private func prepareUnsignedClaim(
        normalizedName: String,
        fingerprint: String,
        walletIndex: Int
    ) async throws -> (WatchOnlyAccountRecord, Data) {
        try await lifecycleCoordinator.withLock {
            if let existingIndex = accounts.firstIndex(where: {
                $0.walletIndex == walletIndex
                    && $0.requestFingerprint == fingerprint
                    && $0.setupState != .active
            }) {
                if accounts[existingIndex].name != normalizedName {
                    accounts[existingIndex].name = normalizedName
                    try persist()
                }
                let refreshed = accounts[existingIndex]
                return try (refreshed, WatchOnlyAccountClaimCodec.encode(record: refreshed))
            }

            let accountIndex = try WatchOnlyAccountStore.reserveAccountIndex(
                walletIndex: walletIndex,
                requestFingerprint: fingerprint,
                defaults: defaults
            )
            let addressType = LDKNode.AddressType.nativeSegwit
            let xpub = try await node.exportWatchOnlyAccountXpub(accountIndex: accountIndex, addressType: addressType)
            let record = WatchOnlyAccountRecord(
                id: UUID(),
                walletIndex: walletIndex,
                accountIndex: accountIndex,
                addressType: addressType.stringValue,
                xpub: xpub,
                requestFingerprint: fingerprint,
                createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                name: normalizedName,
                isTrackingEnabled: false,
                setupState: .pendingDelivery
            )

            accounts.append(record)
            try persist()
            return try (record, WatchOnlyAccountClaimCodec.encode(record: record))
        }
    }

    func acquireSetupAuthorizationAttempt(id: UUID) throws -> WatchOnlyAccountAuthorizationAttempt {
        guard activeAuthorizationAttempt == nil else {
            throw WatchOnlyAccountError.authorizationInProgress
        }
        let attempt = WatchOnlyAccountAuthorizationAttempt(accountId: id)
        activeAuthorizationAttempt = attempt
        preservesAuthorizingStateOnFailure = accounts.first(where: { $0.id == id })?.setupState == .authorizing
        return attempt
    }

    func beginSetupAuthorization(attempt: WatchOnlyAccountAuthorizationAttempt) async throws {
        try requireActiveAuthorizationAttempt(attempt)
        try await lifecycleCoordinator.withLock {
            try requireActiveAuthorizationAttempt(attempt)
            guard let record = accounts.first(where: { $0.id == attempt.accountId && $0.setupState != .active }) else {
                throw WatchOnlyAccountError.authorizationAccountMissing
            }
            preservesAuthorizingStateOnFailure = preservesAuthorizingStateOnFailure || record.setupState == .authorizing
            guard let addressType = LDKNode.AddressType.from(string: record.addressType) else {
                throw WatchOnlyAccountError.invalidExtendedPublicKey
            }

            try await node.setWatchOnlyAccountTracking(
                accountIndex: record.accountIndex,
                addressType: addressType,
                xpub: record.xpub,
                enabled: true
            )
            guard let currentIndex = accounts.firstIndex(where: { $0.id == attempt.accountId && $0.setupState != .active }) else {
                try? await node.setWatchOnlyAccountTracking(
                    accountIndex: record.accountIndex,
                    addressType: addressType,
                    xpub: record.xpub,
                    enabled: false
                )
                throw WatchOnlyAccountError.authorizationAccountMissing
            }
            accounts[currentIndex].setupState = .authorizing
            accounts[currentIndex].isTrackingEnabled = true
            do {
                try persist()
            } catch {
                if let rollbackIndex = accounts.firstIndex(where: { $0.id == attempt.accountId }) {
                    accounts[rollbackIndex].setupState = failureSetupState
                    accounts[rollbackIndex].isTrackingEnabled = isTrackingEnabledOnFailure
                }
                try? await node.setWatchOnlyAccountTracking(
                    accountIndex: record.accountIndex,
                    addressType: addressType,
                    xpub: record.xpub,
                    enabled: isTrackingEnabledOnFailure
                )
                throw error
            }
        }
    }

    func finishSetupAuthorizationAttempt(_ attempt: WatchOnlyAccountAuthorizationAttempt) {
        guard activeAuthorizationAttempt == attempt else { return }
        activeAuthorizationAttempt = nil
        preservesAuthorizingStateOnFailure = false
    }

    func cancelSetupAuthorization(attempt: WatchOnlyAccountAuthorizationAttempt) async throws {
        try requireActiveAuthorizationAttempt(attempt)
        try await Task { @MainActor in
            try await lifecycleCoordinator.withLock {
                try requireActiveAuthorizationAttempt(attempt)
                guard let index = accounts.firstIndex(where: { $0.id == attempt.accountId && $0.setupState != .active }) else { return }
                let record = accounts[index]
                guard let addressType = LDKNode.AddressType.from(string: record.addressType) else {
                    throw WatchOnlyAccountError.invalidExtendedPublicKey
                }

                try await node.setWatchOnlyAccountTracking(
                    accountIndex: record.accountIndex,
                    addressType: addressType,
                    xpub: record.xpub,
                    enabled: isTrackingEnabledOnFailure
                )
                accounts[index].setupState = failureSetupState
                accounts[index].isTrackingEnabled = isTrackingEnabledOnFailure
                do {
                    try persist()
                } catch {
                    if let rollbackIndex = accounts.firstIndex(where: { $0.id == attempt.accountId }) {
                        accounts[rollbackIndex].setupState = record.setupState
                        accounts[rollbackIndex].isTrackingEnabled = record.isTrackingEnabled
                    }
                    try? await node.setWatchOnlyAccountTracking(
                        accountIndex: record.accountIndex,
                        addressType: addressType,
                        xpub: record.xpub,
                        enabled: record.isTrackingEnabled
                    )
                    throw error
                }
            }
        }.value
    }

    func markSetupActive(attempt: WatchOnlyAccountAuthorizationAttempt) async throws {
        try requireActiveAuthorizationAttempt(attempt)
        try await Task { @MainActor in
            try await lifecycleCoordinator.withLock {
                try requireActiveAuthorizationAttempt(attempt)
                guard accounts.contains(where: { $0.id == attempt.accountId }) else {
                    throw WatchOnlyAccountError.authorizationAccountMissing
                }
                accounts = try WatchOnlyAccountStore.markSetupActive(id: attempt.accountId, defaults: defaults)
            }
        }.value
    }

    private func requireActiveAuthorizationAttempt(_ attempt: WatchOnlyAccountAuthorizationAttempt) throws {
        guard activeAuthorizationAttempt == attempt else {
            throw WatchOnlyAccountError.authorizationInProgress
        }
    }

    private var failureSetupState: WatchOnlyAccountSetupState {
        preservesAuthorizingStateOnFailure ? .authorizing : .pendingDelivery
    }

    private var isTrackingEnabledOnFailure: Bool {
        preservesAuthorizingStateOnFailure
    }

    func rename(id: UUID, name: String) async throws {
        let normalizedName = try Self.normalizedName(name)
        try await lifecycleCoordinator.withLock {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].name = normalizedName
            try persist()
        }
    }

    func setTrackingEnabled(id: UUID, enabled: Bool) async throws {
        try await lifecycleCoordinator.withLock {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            let record = accounts[index]
            guard record.setupState == .active else { return }
            guard record.isTrackingEnabled != enabled else { return }
            guard let addressType = LDKNode.AddressType.from(string: record.addressType) else {
                throw WatchOnlyAccountError.invalidExtendedPublicKey
            }

            try await node.setWatchOnlyAccountTracking(
                accountIndex: record.accountIndex,
                addressType: addressType,
                xpub: record.xpub,
                enabled: enabled
            )
            guard let currentIndex = accounts.firstIndex(where: { $0.id == id && $0.setupState == .active }) else {
                try? await node.setWatchOnlyAccountTracking(
                    accountIndex: record.accountIndex,
                    addressType: addressType,
                    xpub: record.xpub,
                    enabled: !enabled
                )
                return
            }
            let wasTrackingEnabled = accounts[currentIndex].isTrackingEnabled
            accounts[currentIndex].isTrackingEnabled = enabled
            do {
                try persist()
            } catch {
                if let rollbackIndex = accounts.firstIndex(where: { $0.id == id }) {
                    accounts[rollbackIndex].isTrackingEnabled = wasTrackingEnabled
                }
                try? await node.setWatchOnlyAccountTracking(
                    accountIndex: record.accountIndex,
                    addressType: addressType,
                    xpub: record.xpub,
                    enabled: !enabled
                )
                throw error
            }
        }
    }

    func restore(
        _ records: [WatchOnlyAccountRecord]?,
        allocationState: WatchOnlyAccountAllocationState?
    ) async throws {
        try await lifecycleCoordinator.withLock {
            try WatchOnlyAccountStore.restore(records, allocationState: allocationState, defaults: defaults)
            try reloadFromStore()
        }
    }

    func reload() async throws {
        try await lifecycleCoordinator.withLock {
            try reloadFromStore()
        }
    }

    func clear() async throws {
        try await Task { @MainActor in
            try await lifecycleCoordinator.withLock {
                WatchOnlyAccountStore.clear(defaults: defaults)
                accounts = []
            }
        }.value
    }

    #if !BITKIT_NOTIFICATION_EXTENSION
        func reconcileTracking() async throws {
            try await lifecycleCoordinator.withLock {
                let snapshot = try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults)
                try await node.reconcileWatchOnlyAccountTracking(
                    records: snapshot.accounts,
                    managedRecords: snapshot.managedAccounts
                )
                try WatchOnlyAccountStore.finishReconciliation(walletIndex: node.currentWalletIndex, defaults: defaults)
            }
        }
    #endif

    private func reloadFromStore() throws {
        accounts = try WatchOnlyAccountStore.load(defaults: defaults)
    }

    private func persist() throws {
        accounts.sort { $0.accountIndex < $1.accountIndex }
        try WatchOnlyAccountStore.save(accounts, defaults: defaults)
    }

    private static func normalizedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 64 else {
            throw WatchOnlyAccountError.invalidAccountName
        }
        return normalized
    }

    private static func requestFingerprint(_ authUrl: String) -> String {
        guard let components = URLComponents(string: authUrl),
              let scheme = components.scheme,
              let host = components.host,
              let relay = singleQueryValue(named: "relay", in: components),
              let secret = singleQueryValue(named: "secret", in: components),
              let capabilities = singleQueryValue(named: "caps", in: components),
              let claim = singleQueryValue(named: companionClaimQueryParameter, in: components)
        else {
            return Data(SHA256.hash(data: Data(authUrl.utf8))).base64EncodedString()
        }
        let fingerprintSource = [
            scheme.lowercased(),
            host.lowercased(),
            components.path,
            relay,
            secret,
            capabilities,
            claim,
        ].joined(separator: "\0")
        return Data(SHA256.hash(data: Data(fingerprintSource.utf8))).base64EncodedString()
    }

    private static func singleQueryValue(named name: String, in components: URLComponents) -> String? {
        let values = components.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
        guard values.count == 1, !values[0].isEmpty else { return nil }
        return values[0]
    }
}

enum WatchOnlyAccountClaimCodec {
    static let version: UInt8 = 1
    static let nativeSegwitAddressType: UInt8 = 0
    static let serializedXpubLength = 78
    static let payloadLength = 1 + 4 + 1 + serializedXpubLength

    static func encode(record: WatchOnlyAccountRecord) throws -> Data {
        guard record.addressType == LDKNode.AddressType.nativeSegwit.stringValue else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }

        let rawXpub = try serializedXpub(record.xpub)
        var claim = Data([version])
        claim.append(contentsOf: withUnsafeBytes(of: record.accountIndex.bigEndian, Array.init))
        claim.append(nativeSegwitAddressType)
        claim.append(rawXpub)
        return claim
    }

    static func serializedXpub(_ xpub: String) throws -> Data {
        guard xpub.count > 4 else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }

        do {
            let serialized = try BitkitCore.serializedExtendedPubkey(xpub: xpub)
            guard serialized.count == serializedXpubLength else {
                throw WatchOnlyAccountError.invalidExtendedPublicKey
            }
            return serialized
        } catch {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }
    }
}
