import Base58Swift
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
    func reconcileWatchOnlyAccountTracking(
        records: [WatchOnlyAccountRecord],
        managedRecords: [WatchOnlyAccountRecord]
    ) async throws
}

extension LightningService: WatchOnlyAccountNodeHandling {}

struct WatchOnlyAccountAllocationState: Codable, Equatable {
    var highestAccountIndexByWallet: [String: UInt32] = [:]
    var pendingAccountIndexByRequest: [String: UInt32] = [:]
}

private struct WatchOnlyAccountData: Codable {
    var accounts: [WatchOnlyAccountRecord] = []
    var allocationState = WatchOnlyAccountAllocationState()
    var accountsPendingUnload: [WatchOnlyAccountRecord]?
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

    private static let legacyAccountsKey = "watchOnlyAccountsV1"
    private static let legacyAllocationKey = "watchOnlyAccountAllocationsV1"
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
        let restoredRecords = records ?? []
        var data = (try? loadData(defaults: defaults)) ?? WatchOnlyAccountData()
        let currentAccounts = data.accounts
        let locallyManagedAccounts = currentAccounts + (data.accountsPendingUnload ?? [])
        let authorizingAccounts = sanitizedAccounts(locallyManagedAccounts.filter { $0.setupState == .authorizing })
        let authorizingIds = Set(authorizingAccounts.map(\.id))
        let authorizingKeys = Set(authorizingAccounts.map(managementKey))
        let authorizingRequestKeys = Set(authorizingAccounts.map {
            allocationRequestKey(walletIndex: $0.walletIndex, requestFingerprint: $0.requestFingerprint)
        })
        let protectedRestorationConflicts = sanitizedAccounts(locallyManagedAccounts.filter { account in
            account.setupState != .authorizing
                && !authorizingIds.contains(account.id)
                && !authorizingKeys.contains(managementKey(account))
                && (account.setupState == .active || !authorizingRequestKeys.contains(
                    allocationRequestKey(walletIndex: account.walletIndex, requestFingerprint: account.requestFingerprint)
                ))
                && shouldProtectLocalAccount(account, from: restoredRecords)
        }).map { promotedTrackingState(for: $0, from: restoredRecords) }
        let protectedLocalAccounts = authorizingAccounts + protectedRestorationConflicts
        let protectedIds = Set(protectedLocalAccounts.map(\.id))
        let protectedKeys = Set(protectedLocalAccounts.map(managementKey))
        let protectedIncompleteRequestKeys = Set(protectedLocalAccounts.compactMap { account -> String? in
            guard account.setupState != .active else { return nil }
            return allocationRequestKey(walletIndex: account.walletIndex, requestFingerprint: account.requestFingerprint)
        })
        let mergedRecords = sanitizedAccounts(restoredRecords.filter {
            !protectedIds.contains($0.id)
                && !protectedKeys.contains(managementKey($0))
                && ($0.setupState == .active || !protectedIncompleteRequestKeys.contains(
                    allocationRequestKey(walletIndex: $0.walletIndex, requestFingerprint: $0.requestFingerprint)
                ))
        }) + protectedLocalAccounts
        let mergedKeys = Set(mergedRecords.map(managementKey))

        let accountsPendingUnload = uniqueAccounts((data.accountsPendingUnload ?? []) + currentAccounts)
            .filter { !mergedKeys.contains(managementKey($0)) }
        data.accountsPendingUnload = accountsPendingUnload.isEmpty ? nil : accountsPendingUnload
        data.accounts = mergedRecords.sorted { $0.accountIndex < $1.accountIndex }

        var localAllocationState = WatchOnlyAccountAllocationState(
            highestAccountIndexByWallet: data.allocationState.highestAccountIndexByWallet.filter {
                isValidAccountIndex($0.value)
            },
            pendingAccountIndexByRequest: data.allocationState.pendingAccountIndexByRequest.filter {
                isValidAccountIndex($0.value)
            }
        )
        localAllocationState.reconcileAccountIndexes(locallyManagedAccounts)
        for (requestKey, accountIndex) in localAllocationState.pendingAccountIndexByRequest {
            guard let walletIndex = walletIndex(fromAllocationRequestKey: requestKey) else { continue }
            let walletKey = String(walletIndex)
            localAllocationState.highestAccountIndexByWallet[walletKey] = max(
                localAllocationState.highestAccountIndexByWallet[walletKey] ?? 0,
                accountIndex
            )
        }
        let localHighestAccountIndexByWallet = localAllocationState.highestAccountIndexByWallet
        var highestAccountIndexByWallet = localHighestAccountIndexByWallet

        if let restoredAllocationState {
            for (walletKey, restoredIndex) in restoredAllocationState.highestAccountIndexByWallet {
                guard isValidAccountIndex(restoredIndex) else { continue }
                highestAccountIndexByWallet[walletKey] = max(
                    highestAccountIndexByWallet[walletKey] ?? 0,
                    restoredIndex
                )
            }
            for (requestKey, restoredIndex) in restoredAllocationState.pendingAccountIndexByRequest {
                guard isValidAccountIndex(restoredIndex),
                      let walletIndex = walletIndex(fromAllocationRequestKey: requestKey)
                else { continue }
                let walletKey = String(walletIndex)
                highestAccountIndexByWallet[walletKey] = max(
                    highestAccountIndexByWallet[walletKey] ?? 0,
                    restoredIndex
                )
            }
        }

        var pendingAccountIndexByRequest = validPendingAccountIndexes(
            restoredAllocationState?.pendingAccountIndexByRequest ?? [:],
            accounts: mergedRecords,
            restoredAccounts: restoredRecords,
            blockedAccounts: accountsPendingUnload,
            localHighestAccountIndexByWallet: localHighestAccountIndexByWallet,
            localPendingAccountIndexByRequest: localAllocationState.pendingAccountIndexByRequest
        )
        for account in authorizingAccounts {
            let accountSlot = allocationSlotKey(walletIndex: account.walletIndex, accountIndex: account.accountIndex)
            pendingAccountIndexByRequest = pendingAccountIndexByRequest.filter { requestKey, accountIndex in
                guard let walletIndex = walletIndex(fromAllocationRequestKey: requestKey) else { return false }
                return allocationSlotKey(walletIndex: walletIndex, accountIndex: accountIndex) != accountSlot
            }
            let requestKey = allocationRequestKey(walletIndex: account.walletIndex, requestFingerprint: account.requestFingerprint)
            pendingAccountIndexByRequest[requestKey] = account.accountIndex
        }

        for (requestKey, accountIndex) in pendingAccountIndexByRequest {
            guard let walletIndex = walletIndex(fromAllocationRequestKey: requestKey) else { continue }
            let walletKey = String(walletIndex)
            highestAccountIndexByWallet[walletKey] = max(
                highestAccountIndexByWallet[walletKey] ?? 0,
                accountIndex
            )
        }

        data.allocationState = WatchOnlyAccountAllocationState(
            highestAccountIndexByWallet: highestAccountIndexByWallet,
            pendingAccountIndexByRequest: pendingAccountIndexByRequest
        )

        data.allocationState.reconcileAccountIndexes(restoredRecords + mergedRecords + accountsPendingUnload)
        try saveData(data, defaults: defaults)
    }

    static func reconciliationSnapshot(defaults: UserDefaults = .standard) throws -> WatchOnlyAccountReconciliationSnapshot {
        let data = try loadData(defaults: defaults)
        return WatchOnlyAccountReconciliationSnapshot(
            accounts: data.accounts.sorted { $0.accountIndex < $1.accountIndex },
            managedAccounts: uniqueAccounts(data.accounts + (data.accountsPendingUnload ?? []))
        )
    }

    static func finishReconciliation(walletIndex: Int, defaults: UserDefaults = .standard) throws {
        var data = try loadData(defaults: defaults)
        guard let accountsPendingUnload = data.accountsPendingUnload,
              accountsPendingUnload.contains(where: { $0.walletIndex == walletIndex })
        else { return }
        let remainingAccounts = accountsPendingUnload.filter { $0.walletIndex != walletIndex }
        data.accountsPendingUnload = remainingAccounts.isEmpty ? nil : remainingAccounts
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

    static func completeAllocation(walletIndex: Int, requestFingerprint: String, defaults: UserDefaults = .standard) throws {
        var data = try loadData(defaults: defaults)
        data.allocationState.pendingAccountIndexByRequest.removeValue(
            forKey: allocationRequestKey(walletIndex: walletIndex, requestFingerprint: requestFingerprint)
        )
        try saveData(data, defaults: defaults)
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
        defaults.removeObject(forKey: legacyAccountsKey)
        defaults.removeObject(forKey: legacyAllocationKey)
    }

    private static func loadData(defaults: UserDefaults) throws -> WatchOnlyAccountData {
        if let encoded = defaults.data(forKey: dataKey) {
            return try JSONDecoder().decode(WatchOnlyAccountData.self, from: encoded)
        }

        let legacyAccountsData = defaults.data(forKey: legacyAccountsKey)
        let legacyAllocationData = defaults.data(forKey: legacyAllocationKey)
        guard legacyAccountsData != nil || legacyAllocationData != nil else {
            return WatchOnlyAccountData()
        }

        let accounts = try legacyAccountsData.map { try JSONDecoder().decode([WatchOnlyAccountRecord].self, from: $0) } ?? []
        var allocationState = try legacyAllocationData.map {
            try JSONDecoder().decode(WatchOnlyAccountAllocationState.self, from: $0)
        } ?? WatchOnlyAccountAllocationState()
        allocationState.reconcileAccountIndexes(accounts)

        return WatchOnlyAccountData(accounts: accounts, allocationState: allocationState)
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

    private static func validPendingAccountIndexes(
        _ pendingAccountIndexes: [String: UInt32],
        accounts: [WatchOnlyAccountRecord],
        restoredAccounts: [WatchOnlyAccountRecord],
        blockedAccounts: [WatchOnlyAccountRecord],
        localHighestAccountIndexByWallet: [String: UInt32],
        localPendingAccountIndexByRequest: [String: UInt32]
    ) -> [String: UInt32] {
        let accountsBySlot = Dictionary(grouping: accounts) {
            allocationSlotKey(walletIndex: $0.walletIndex, accountIndex: $0.accountIndex)
        }
        let incompleteAccountSlotsByRequest: [String: String] = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account -> (String, String)? in
                guard account.setupState != .active else { return nil }
                let requestKey = allocationRequestKey(
                    walletIndex: account.walletIndex,
                    requestFingerprint: account.requestFingerprint
                )
                return (requestKey, allocationSlotKey(walletIndex: account.walletIndex, accountIndex: account.accountIndex))
            }
        )
        let restoredIncompleteRequestKeys = Set(restoredAccounts.compactMap { account -> String? in
            guard account.setupState != .active else { return nil }
            return allocationRequestKey(walletIndex: account.walletIndex, requestFingerprint: account.requestFingerprint)
        })
        let restoredAccountSlots = Set(restoredAccounts.map {
            allocationSlotKey(walletIndex: $0.walletIndex, accountIndex: $0.accountIndex)
        })
        let blockedSlots = Set(blockedAccounts.map {
            allocationSlotKey(walletIndex: $0.walletIndex, accountIndex: $0.accountIndex)
        })
        let candidates = pendingAccountIndexes.compactMap { requestKey, accountIndex -> (String, UInt32, String)? in
            guard isValidAccountIndex(accountIndex),
                  let walletIndex = walletIndex(fromAllocationRequestKey: requestKey)
            else { return nil }
            let slot = allocationSlotKey(walletIndex: walletIndex, accountIndex: accountIndex)
            let incompleteAccountSlot = incompleteAccountSlotsByRequest[requestKey]
            guard !restoredIncompleteRequestKeys.contains(requestKey) || incompleteAccountSlot != nil,
                  incompleteAccountSlot == nil || incompleteAccountSlot == slot,
                  !restoredAccountSlots.contains(slot) || incompleteAccountSlot == slot
            else { return nil }
            if let localAccountIndex = localPendingAccountIndexByRequest[requestKey],
               localAccountIndex != accountIndex
            {
                return nil
            }
            let slotAccounts = accountsBySlot[slot] ?? []
            if slotAccounts.isEmpty {
                guard !blockedSlots.contains(slot),
                      localPendingAccountIndexByRequest[requestKey] == accountIndex
                      || accountIndex > (localHighestAccountIndexByWallet[String(walletIndex)] ?? 0)
                else { return nil }
            } else {
                guard slotAccounts.allSatisfy({
                    $0.setupState != .active
                        && allocationRequestKey(walletIndex: $0.walletIndex, requestFingerprint: $0.requestFingerprint) == requestKey
                }) else { return nil }
            }
            return (requestKey, accountIndex, slot)
        }

        return Dictionary(grouping: candidates, by: { $0.2 }).values.reduce(into: [:]) { validIndexes, slotCandidates in
            guard slotCandidates.count == 1, let candidate = slotCandidates.first else { return }
            validIndexes[candidate.0] = candidate.1
        }
    }

    private static func uniqueAccounts(_ accounts: [WatchOnlyAccountRecord]) -> [WatchOnlyAccountRecord] {
        Dictionary(grouping: accounts, by: managementKey).values.compactMap(\.last).sorted { $0.accountIndex < $1.accountIndex }
    }

    private static func sanitizedAccounts(_ accounts: [WatchOnlyAccountRecord]) -> [WatchOnlyAccountRecord] {
        var ids = Set<UUID>()
        var managementKeys = Set<String>()
        var incompleteRequestKeys = Set<String>()

        return accounts.filter(isUsableAccount).sorted(by: accountRestorationOrder).filter { account in
            let accountManagementKey = managementKey(account)
            let incompleteRequestKey = allocationRequestKey(
                walletIndex: account.walletIndex,
                requestFingerprint: account.requestFingerprint
            )
            guard !ids.contains(account.id),
                  !managementKeys.contains(accountManagementKey),
                  account.setupState == .active || !incompleteRequestKeys.contains(incompleteRequestKey)
            else { return false }

            ids.insert(account.id)
            managementKeys.insert(accountManagementKey)
            if account.setupState != .active {
                incompleteRequestKeys.insert(incompleteRequestKey)
            }
            return true
        }.map(normalizedTrackingState)
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

    private static func shouldProtectLocalAccount(
        _ localAccount: WatchOnlyAccountRecord,
        from restoredAccounts: [WatchOnlyAccountRecord]
    ) -> Bool {
        let conflicts = restoredAccounts.filter(isUsableAccount).filter {
            managementKey($0) == managementKey(localAccount) || $0.id == localAccount.id
        }
        guard let highestRestoredPriority = conflicts.map({ setupStatePriority($0.setupState) }).max() else {
            return false
        }
        let localPriority = setupStatePriority(localAccount.setupState)
        if localPriority != highestRestoredPriority {
            return localPriority > highestRestoredPriority
        }
        return conflicts.contains {
            setupStatePriority($0.setupState) == highestRestoredPriority
                && !hasSameOwner(localAccount, $0)
        }
    }

    private static func promotedTrackingState(
        for localAccount: WatchOnlyAccountRecord,
        from restoredAccounts: [WatchOnlyAccountRecord]
    ) -> WatchOnlyAccountRecord {
        guard localAccount.setupState == .active,
              restoredAccounts.filter(isUsableAccount).contains(where: {
                  managementKey($0) == managementKey(localAccount)
                      && ($0.setupState == .authorizing || $0.setupState == .active && $0.isTrackingEnabled)
              })
        else { return localAccount }
        var localAccount = localAccount
        localAccount.isTrackingEnabled = true
        return localAccount
    }

    private static func hasSameOwner(_ lhs: WatchOnlyAccountRecord, _ rhs: WatchOnlyAccountRecord) -> Bool {
        managementKey(lhs) == managementKey(rhs)
            && lhs.requestFingerprint == rhs.requestFingerprint
            && lhs.xpub == rhs.xpub
    }

    private static func accountRestorationOrder(_ lhs: WatchOnlyAccountRecord, _ rhs: WatchOnlyAccountRecord) -> Bool {
        let lhsPriority = setupStatePriority(lhs.setupState)
        let rhsPriority = setupStatePriority(rhs.setupState)
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.walletIndex != rhs.walletIndex { return lhs.walletIndex < rhs.walletIndex }
        if lhs.accountIndex != rhs.accountIndex { return lhs.accountIndex < rhs.accountIndex }
        if lhs.addressType != rhs.addressType { return lhs.addressType < rhs.addressType }
        if lhs.requestFingerprint != rhs.requestFingerprint { return lhs.requestFingerprint < rhs.requestFingerprint }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        if lhs.xpub != rhs.xpub { return lhs.xpub < rhs.xpub }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.isTrackingEnabled && !rhs.isTrackingEnabled
    }

    private static func setupStatePriority(_ state: WatchOnlyAccountSetupState) -> Int {
        switch state {
        case .active: return 3
        case .authorizing: return 2
        case .pendingDelivery: return 1
        }
    }

    private static func managementKey(_ account: WatchOnlyAccountRecord) -> String {
        "\(account.walletIndex):\(account.addressType):\(account.accountIndex)"
    }
}

private extension WatchOnlyAccountAllocationState {
    mutating func reconcileAccountIndexes(_ accounts: [WatchOnlyAccountRecord]) {
        for (walletIndex, walletAccounts) in Dictionary(grouping: accounts, by: \WatchOnlyAccountRecord.walletIndex) {
            guard let accountIndex = walletAccounts.map(\.accountIndex).filter({
                $0 > 0 && $0 <= UInt32(Int32.max)
            }).max() else { continue }
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
    private var preparationTasks: [String: Task<(WatchOnlyAccountRecord, Data), Error>] = [:]
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
        let walletIndex = node.currentWalletIndex
        let taskKey = "\(walletIndex):\(fingerprint)"

        if let preparationTask = preparationTasks[taskKey] {
            return try await preparationTask.value
        }

        let preparationTask = Task { @MainActor in
            try await self.prepareUnsignedClaim(
                normalizedName: normalizedName,
                fingerprint: fingerprint,
                walletIndex: walletIndex
            )
        }
        preparationTasks[taskKey] = preparationTask
        defer { preparationTasks[taskKey] = nil }
        return try await preparationTask.value
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
        guard xpub.count > 4,
              let decoded = Base58.base58CheckDecode(xpub),
              decoded.count == serializedXpubLength
        else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }
        return Data(decoded)
    }
}
