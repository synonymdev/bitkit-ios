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

enum WatchOnlyAccountError: LocalizedError, Equatable {
    case invalidAccountName
    case invalidExtendedPublicKey

    var errorDescription: String? {
        switch self {
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
}

extension LightningService: WatchOnlyAccountNodeHandling {}

struct WatchOnlyAccountAllocationState: Codable, Equatable {
    var highestAccountIndexByWallet: [String: UInt32] = [:]
    var pendingAccountIndexByRequest: [String: UInt32] = [:]
}

private struct WatchOnlyAccountData: Codable {
    var accounts: [WatchOnlyAccountRecord] = []
    var allocationState = WatchOnlyAccountAllocationState()
}

struct WatchOnlyAccountBackupSnapshot {
    let accounts: [WatchOnlyAccountRecord]
    let allocationState: WatchOnlyAccountAllocationState
}

enum WatchOnlyAccountStore {
    static let walletBackupDataChangedPublisher = walletBackupDataChangedSubject.eraseToAnyPublisher()

    static let dataKey = "watchOnlyAccountDataV1"

    private static let legacyAccountsKey = "watchOnlyAccountsV1"
    private static let legacyAllocationKey = "watchOnlyAccountAllocationsV1"
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
        data.accounts = restoredRecords.sorted { $0.accountIndex < $1.accountIndex }

        var highestAccountIndexByWallet = data.allocationState.highestAccountIndexByWallet

        if let restoredAllocationState {
            for (walletKey, restoredIndex) in restoredAllocationState.highestAccountIndexByWallet {
                highestAccountIndexByWallet[walletKey] = max(
                    highestAccountIndexByWallet[walletKey] ?? 0,
                    restoredIndex
                )
            }
        }

        data.allocationState = WatchOnlyAccountAllocationState(
            highestAccountIndexByWallet: highestAccountIndexByWallet,
            pendingAccountIndexByRequest: restoredAllocationState?.pendingAccountIndexByRequest ?? [:]
        )

        data.allocationState.reconcileAccountIndexes(restoredRecords)
        try saveData(data, defaults: defaults)
    }

    static func reserveAccountIndex(walletIndex: Int, requestFingerprint: String, defaults: UserDefaults = .standard) throws -> UInt32 {
        var data = try loadData(defaults: defaults)
        let requestKey = allocationRequestKey(walletIndex: walletIndex, requestFingerprint: requestFingerprint)
        if let pendingAccountIndex = data.allocationState.pendingAccountIndexByRequest[requestKey] {
            return pendingAccountIndex
        }

        let walletKey = String(walletIndex)
        let highestPersistedAccountIndex = data.accounts
            .filter { $0.walletIndex == walletIndex }
            .map(\.accountIndex)
            .max() ?? 0
        let highestAccountIndex = max(
            data.allocationState.highestAccountIndexByWallet[walletKey] ?? 0,
            highestPersistedAccountIndex
        )
        guard highestAccountIndex < UInt32(Int32.max) else {
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
            return data.accounts
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

        let migrated = WatchOnlyAccountData(accounts: accounts, allocationState: allocationState)
        try saveData(migrated, defaults: defaults)
        return migrated
    }

    private static func saveData(_ data: WatchOnlyAccountData, defaults: UserDefaults) throws {
        try defaults.set(JSONEncoder().encode(data), forKey: dataKey)
        walletBackupDataChangedSubject.send()
    }

    private static func allocationRequestKey(walletIndex: Int, requestFingerprint: String) -> String {
        "\(walletIndex):\(requestFingerprint)"
    }
}

private extension WatchOnlyAccountAllocationState {
    mutating func reconcileAccountIndexes(_ accounts: [WatchOnlyAccountRecord]) {
        for (walletIndex, walletAccounts) in Dictionary(grouping: accounts, by: \WatchOnlyAccountRecord.walletIndex) {
            guard let accountIndex = walletAccounts.map(\.accountIndex).max() else { continue }
            let walletKey = String(walletIndex)
            highestAccountIndexByWallet[walletKey] = max(highestAccountIndexByWallet[walletKey] ?? 0, accountIndex)
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
    private let node: WatchOnlyAccountNodeHandling
    private var preparationTasks: [String: Task<(WatchOnlyAccountRecord, Data), Error>] = [:]

    init(
        defaults: UserDefaults = .standard,
        node: WatchOnlyAccountNodeHandling = LightningService.shared
    ) {
        self.defaults = defaults
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

    func beginSetupAuthorization(id: UUID) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id && $0.setupState != .active }) else { return }
        let record = accounts[index]
        guard let addressType = LDKNode.AddressType.from(string: record.addressType) else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }

        try await node.setWatchOnlyAccountTracking(
            accountIndex: record.accountIndex,
            addressType: addressType,
            xpub: record.xpub,
            enabled: true
        )
        accounts[index].setupState = .authorizing
        accounts[index].isTrackingEnabled = true
        do {
            try persist()
        } catch {
            try? await node.setWatchOnlyAccountTracking(
                accountIndex: record.accountIndex,
                addressType: addressType,
                xpub: record.xpub,
                enabled: false
            )
            accounts[index] = record
            throw error
        }
    }

    func cancelSetupAuthorization(id: UUID) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id && $0.setupState != .active }) else { return }
        let record = accounts[index]
        guard let addressType = LDKNode.AddressType.from(string: record.addressType) else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }

        accounts[index].setupState = .pendingDelivery
        accounts[index].isTrackingEnabled = false
        try persist()
        try await node.setWatchOnlyAccountTracking(
            accountIndex: record.accountIndex,
            addressType: addressType,
            xpub: record.xpub,
            enabled: false
        )
    }

    func markSetupActive(id: UUID) throws {
        accounts = try WatchOnlyAccountStore.markSetupActive(id: id, defaults: defaults)
    }

    func rename(id: UUID, name: String) throws {
        let normalizedName = try Self.normalizedName(name)
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = normalizedName
        try persist()
    }

    func setTrackingEnabled(id: UUID, enabled: Bool) async throws {
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
        accounts[index].isTrackingEnabled = enabled
        try persist()
    }

    func reload() throws {
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
