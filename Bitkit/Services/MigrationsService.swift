import BitkitCore
import Foundation
import Security

// MARK: - MMKV Parser

/// Lightweight parser for MMKV binary format (react-native-mmkv)
/// MMKV stores data as: [4-byte size (little-endian)][4-byte marker][key-value pairs...]
/// Each pair: [varint key_length][key_bytes][varint value_length][value_bytes]
struct MMKVParser {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func parse() -> [String: String] {
        guard data.count > 8 else { return [:] }

        let contentSize = Int(data[0]) |
            Int(data[1]) << 8 |
            Int(data[2]) << 16 |
            Int(data[3]) << 24
        let endOffset = min(8 + contentSize, data.count)

        var result: [String: String] = [:]
        var offset = 8

        while offset < endOffset {
            guard let (keyLength, keyLengthBytes) = readVarint(at: offset, endOffset: endOffset) else { break }
            offset += keyLengthBytes

            guard offset + keyLength <= endOffset else { break }
            let keyData = data.subdata(in: offset ..< offset + keyLength)
            guard let key = String(data: keyData, encoding: .utf8) else { break }
            offset += keyLength

            guard let (valueLength, valueLengthBytes) = readVarint(at: offset, endOffset: endOffset) else { break }
            offset += valueLengthBytes

            guard offset + valueLength <= endOffset else { break }
            let valueData = data.subdata(in: offset ..< offset + valueLength)

            if let value = String(data: valueData, encoding: .utf8) {
                result[key] = value
            } else if let value = String(data: valueData, encoding: .isoLatin1) {
                result[key] = value
            }
            offset += valueLength
        }

        return result
    }

    private func readVarint(at offset: Int, endOffset: Int) -> (Int, Int)? {
        var result = 0
        var shift = 0
        var bytesRead = 0
        var currentOffset = offset

        while currentOffset < endOffset {
            let byte = data[currentOffset]
            result |= Int(byte & 0x7F) << shift

            bytesRead += 1
            currentOffset += 1

            if byte & 0x80 == 0 {
                return (result, bytesRead)
            }

            shift += 7
            if shift >= 64 { return nil }
        }

        return nil
    }
}

// MARK: - RN Redux State Types

struct RNSettings: Codable {
    var enableAutoReadClipboard: Bool?
    var enableSendAmountWarning: Bool?
    var enableSwipeToHideBalance: Bool?
    var pin: Bool?
    var pinOnLaunch: Bool?
    var pinOnIdle: Bool?
    var pinForPayments: Bool?
    var biometrics: Bool?
    var rbf: Bool?
    var theme: String?
    var unit: String?
    var denomination: String?
    var selectedCurrency: String?
    var selectedLanguage: String?
    var coinSelectAuto: Bool?
    var coinSelectPreference: String?
    var enableDevOptions: Bool?
    var enableOfflinePayments: Bool?
    var enableQuickpay: Bool?
    var quickpayAmount: Int?
    var showWidgets: Bool?
    var showWidgetTitles: Bool?
    var transactionSpeed: String?
    var customFeeRate: Int?
    var hideBalance: Bool?
    var hideBalanceOnOpen: Bool?
    var quickpayIntroSeen: Bool?
    var shopIntroSeen: Bool?
    var transferIntroSeen: Bool?
    var spendingIntroSeen: Bool?
    var savingsIntroSeen: Bool?
}

struct RNMetadata: Codable {
    var tags: [String: [String]]?
    var lastUsedTags: [String]?
}

struct RNActivityState: Codable {
    var items: [RNActivityItem]?
}

struct RNActivityItem: Codable {
    var id: String
    var activityType: String
    var txType: String
    var txId: String?
    var value: Int64
    var fee: Int64?
    var feeRate: Int64?
    var address: String?
    var confirmed: Bool?
    var timestamp: Int64
    var isBoosted: Bool?
    var isTransfer: Bool?
    var exists: Bool?
    var confirmTimestamp: Int64?
    var channelId: String?
    var transferTxId: String?
    var status: String?
    var message: String?
    var preimage: String?
    var boostedParents: [String]?
}

struct RNTransfer: Codable {
    var txId: String?
    var type: String?
}

struct RNBoostedTransaction: Codable {
    var oldTxId: String?
    var newTxId: String?
    var childTransaction: String?
    var parentTransactions: [String]?
    var type: String?
    var fee: Int64?
}

struct RNWalletBackup: Codable {
    var transfers: [String: [RNTransfer]]?
    var boostedTransactions: [String: [String: RNBoostedTransaction]]?
}

struct RNWalletState: Codable {
    var wallets: [String: RNWalletData]?
}

struct RNWalletData: Codable {
    var boostedTransactions: [String: [String: RNBoostedTransaction]]?
    var transfers: [String: [RNTransfer]]?
}

struct RNLightningState: Codable {
    var nodes: [String: RNLightningNode]?
}

struct RNLightningNode: Codable {
    var channels: [String: [String: RNChannel]]?
}

struct RNChannel: Codable {
    var channel_id: String
    var status: String?
    var createdAt: Int64?
    var counterparty_node_id: String?
    var funding_txid: String?
    var channel_value_satoshis: UInt64?
    var balance_sat: UInt64?
    var claimable_balances: [RNClaimableBalance]?
    var outbound_capacity_sat: UInt64?
    var inbound_capacity_sat: UInt64?
    var is_usable: Bool?
    var is_channel_ready: Bool?
    var confirmations: UInt32?
    var confirmations_required: UInt32?
    var short_channel_id: String?
    var closureReason: String?
    var unspendable_punishment_reserve: UInt64?
    var counterparty_unspendable_punishment_reserve: UInt64?
}

struct RNClaimableBalance: Codable {
    var amount_satoshis: UInt64?
    var type: String?
}

struct RNWidgets: Codable {
    var onboardedWidgets: Bool?
    var sortOrder: [String]?
}

struct RNTodos: Codable {
    var hide: [String: Int64]?
}

struct RNWidgetsWithOptions {
    var widgets: RNWidgets
    var widgetOptions: [String: Data] // widget name -> JSON options data
}

// MARK: - Widget Types for Migration

enum MigrationWidgetType: String, Codable {
    case price
    case news
    case blocks
    case facts
    case calculator
    case weather
}

struct MigrationSavedWidget: Codable {
    let type: MigrationWidgetType
    let optionsData: Data?

    init(type: MigrationWidgetType, optionsData: Data? = nil) {
        self.type = type
        self.optionsData = optionsData
    }
}

private enum MigrationGraphPeriod: String, Codable {
    case oneDay = "1D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case oneYear = "1Y"
}

private struct MigrationPriceWidgetOptions: Codable {
    var selectedPairs: [String]
    var selectedPeriod: MigrationGraphPeriod
    var showSource: Bool
}

private struct MigrationWeatherWidgetOptions: Codable {
    var showStatus: Bool
    var showText: Bool
    var showMedian: Bool
    var showNextBlockFee: Bool
}

private struct MigrationNewsWidgetOptions: Codable {
    var showDate: Bool
    var showTitle: Bool
    var showSource: Bool
}

private struct MigrationBlocksWidgetOptions: Codable {
    var height: Bool
    var time: Bool
    var date: Bool
    var transactionCount: Bool
    var size: Bool
    var weight: Bool
    var difficulty: Bool
    var hash: Bool
    var merkleRoot: Bool
    var showSource: Bool
}

private struct MigrationFactsWidgetOptions: Codable {
    var showSource: Bool
}

// MARK: - RN Migration Keys

enum RNKeychainKey {
    case mnemonic(walletName: String)
    case passphrase(walletName: String)
    case pin

    var service: String {
        switch self {
        case let .mnemonic(walletName):
            return walletName
        case let .passphrase(walletName):
            return "\(walletName)passphrase"
        case .pin:
            return "pin"
        }
    }
}

// MARK: - Channel Migration Data

struct PendingChannelMigration {
    let channelManager: Data
    let channelMonitors: [Data]
}

// MARK: - MigrationsService

class MigrationsService: ObservableObject {
    static var shared = MigrationsService()

    private let fileManager = FileManager.default

    private static let rnMigrationCompletedKey = "rnMigrationCompleted"
    private static let rnMigrationCheckedKey = "rnMigrationChecked"

    @Published var isShowingMigrationLoading = false
    var isRestoringFromRNRemoteBackup = false

    var pendingChannelMigration: PendingChannelMigration?

    /// Stored activity data from RN remote backup for reapplying metadata after sync
    private var pendingRemoteActivityData: [RNActivityItem]?

    /// Stored transfer info from RN wallet backup for marking on-chain txs as transfers
    private var pendingRemoteTransfers: [String: String]? // txId -> channelId

    /// Stored boost info from RN wallet backup for applying boostTxIds to activities
    private var pendingRemoteBoosts: [String: String]? // oldTxId -> newTxId

    /// Stored metadata from RN backup for reapplying after on-chain activities are synced
    private var pendingRemoteMetadata: RNMetadata?

    /// Stored paid orders from RN backup for creating transfers after wallet starts
    private var pendingRemotePaidOrders: [String: String]? // orderId -> txId

    private init() {}

    private var rnNetworkString: String {
        switch Env.network {
        case .bitcoin:
            return "bitcoin"
        case .regtest:
            return "bitcoinRegtest"
        case .testnet:
            return "bitcoinTestnet"
        case .signet:
            return "signet"
        }
    }

    private let rnWalletName = "wallet0"
}

// MARK: - RN Keychain Access

extension MigrationsService {
    func loadFromRNKeychain(key: RNKeychainKey) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var dataTypeRef: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        // RN keychain library may store items without kSecAttrAccount in some versions
        if status == errSecItemNotFound {
            let queryWithoutAccount: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnData as String: kCFBooleanTrue!,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            status = SecItemCopyMatching(queryWithoutAccount as CFDictionary, &dataTypeRef)
        }

        if status == errSecItemNotFound {
            Logger.debug("RN keychain key '\(key.service)' not found", context: "Migration")
            return nil
        }

        if status != noErr {
            Logger.error("Failed to load RN keychain key '\(key.service)': \(status)", context: "Migration")
            throw KeychainError.failedToLoad
        }

        Logger.debug("RN keychain key '\(key.service)' loaded successfully", context: "Migration")
        return dataTypeRef as? Data
    }

    func loadStringFromRNKeychain(key: RNKeychainKey) throws -> String? {
        guard let data = try loadFromRNKeychain(key: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - RN Migration Detection & Execution

extension MigrationsService {
    var isMigrationChecked: Bool {
        UserDefaults.standard.bool(forKey: Self.rnMigrationCheckedKey)
    }

    func hasRNWalletData() -> Bool {
        do {
            let mnemonic = try loadStringFromRNKeychain(key: .mnemonic(walletName: rnWalletName))
            return mnemonic?.isEmpty == false
        } catch {
            Logger.error("Error checking for RN wallet data: \(error)", context: "Migration")
            return false
        }
    }

    func hasNativeWalletData() -> Bool {
        do {
            return try Keychain.exists(key: .bip39Mnemonic(index: 0))
        } catch {
            return false
        }
    }

    private var rnLdkBasePath: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("ldk")
    }

    private var rnLdkAccountPath: URL {
        let accountName = "\(rnWalletName)\(rnNetworkString)ldkaccountv3"
        return rnLdkBasePath.appendingPathComponent(accountName)
    }

    func hasRNLdkData() -> Bool {
        let channelManagerPath = rnLdkAccountPath.appendingPathComponent("channel_manager.bin")
        let exists = fileManager.fileExists(atPath: channelManagerPath.path)
        Logger.debug("RN LDK path: \(rnLdkAccountPath.path), channel_manager exists: \(exists)", context: "Migration")
        return exists
    }

    func migrateFromReactNative(walletIndex: Int = 0) async throws {
        Logger.info("Starting RN migration", context: "Migration")

        try migrateMnemonic(walletIndex: walletIndex)
        try migratePassphrase(walletIndex: walletIndex)
        try migratePin()

        if hasRNLdkData() {
            try await migrateLdkData()
        }

        if hasRNMmkvData() {
            Logger.info("Found MMKV data, starting migration", context: "Migration")
            await migrateMMKVData()
        } else {
            Logger.warn("No MMKV data found, skipping settings/activities migration", context: "Migration")
        }

        UserDefaults.standard.set(true, forKey: Self.rnMigrationCompletedKey)
        UserDefaults.standard.set(true, forKey: Self.rnMigrationCheckedKey)
        Logger.info("RN migration completed", context: "Migration")
    }

    private func migrateMnemonic(walletIndex: Int) throws {
        guard let mnemonic = try loadStringFromRNKeychain(key: .mnemonic(walletName: rnWalletName)) else {
            throw AppError(message: "No RN mnemonic found", debugMessage: nil)
        }

        let words = mnemonic.split(separator: " ")
        guard words.count == 12 || words.count == 24 else {
            throw AppError(message: "Invalid mnemonic: \(words.count) words", debugMessage: nil)
        }

        do {
            try validateMnemonic(mnemonicPhrase: mnemonic)
        } catch {
            throw AppError(message: "Invalid BIP39 mnemonic", debugMessage: nil)
        }

        try Keychain.saveString(key: .bip39Mnemonic(index: walletIndex), str: mnemonic)
    }

    private func migratePassphrase(walletIndex: Int) throws {
        guard let passphrase = try loadStringFromRNKeychain(key: .passphrase(walletName: rnWalletName)),
              !passphrase.isEmpty
        else {
            return
        }
        try Keychain.saveString(key: .bip39Passphrase(index: walletIndex), str: passphrase)
    }

    private func migratePin() throws {
        guard let pin = try loadStringFromRNKeychain(key: .pin),
              !pin.isEmpty
        else {
            return
        }

        try Keychain.saveString(key: .securityPin, str: pin)
    }

    private func clearPinSettings() {
        try? Keychain.delete(key: .securityPin)

        UserDefaults.standard.removeObject(forKey: "requirePinForPayments")
        UserDefaults.standard.removeObject(forKey: "useBiometrics")
        UserDefaults.standard.removeObject(forKey: "pinFailedAttempts")
        UserDefaults.standard.removeObject(forKey: "pinOnLaunch")
        UserDefaults.standard.removeObject(forKey: "pinOnIdle")
        UserDefaults.standard.removeObject(forKey: "pin")
    }

    private func migrateLdkData() async throws {
        let accountPath = rnLdkAccountPath
        let managerPath = accountPath.appendingPathComponent("channel_manager.bin")

        guard fileManager.fileExists(atPath: managerPath.path) else {
            return
        }

        let managerData = try Data(contentsOf: managerPath)
        var monitors: [Data] = []

        let channelsPath = accountPath.appendingPathComponent("channels")
        let monitorsPath = accountPath.appendingPathComponent("monitors")
        let monitorDir = fileManager.fileExists(atPath: channelsPath.path) ? channelsPath : monitorsPath

        if fileManager.fileExists(atPath: monitorDir.path) {
            let monitorFiles = try fileManager.contentsOfDirectory(atPath: monitorDir.path)
            for file in monitorFiles where file.hasSuffix(".bin") {
                let monitorData = try Data(contentsOf: monitorDir.appendingPathComponent(file))
                monitors.append(monitorData)
            }
        }

        pendingChannelMigration = PendingChannelMigration(
            channelManager: managerData,
            channelMonitors: monitors
        )
        Logger.info("Prepared \(monitors.count) channel monitors for migration", context: "Migration")
    }

    func markMigrationChecked() {
        UserDefaults.standard.set(true, forKey: Self.rnMigrationCheckedKey)
    }
}

// MARK: - MMKV Data Migration

extension MigrationsService {
    private var rnMmkvPath: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("mmkv/mmkv.default")
    }

    func hasRNMmkvData() -> Bool {
        fileManager.fileExists(atPath: rnMmkvPath.path)
    }

    func loadRNMmkvData() -> [String: String]? {
        guard hasRNMmkvData() else {
            Logger.debug("No MMKV data found at \(rnMmkvPath.path)", context: "Migration")
            return nil
        }

        do {
            let data = try Data(contentsOf: rnMmkvPath)
            let parser = MMKVParser(data: data)
            let parsed = parser.parse()
            Logger.debug("Parsed \(parsed.count) keys from MMKV", context: "Migration")
            return parsed.isEmpty ? nil : parsed
        } catch {
            Logger.error("Failed to read MMKV data: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNSettings(from mmkvData: [String: String]) -> RNSettings? {
        guard let rootJson = mmkvData["persist:root"] else {
            Logger.debug("persist:root not found in MMKV. Available keys: \(Array(mmkvData.keys))", context: "Migration")
            return nil
        }

        var jsonString = rootJson
        if let jsonStart = rootJson.firstIndex(of: "{") {
            jsonString = String(rootJson[jsonStart...])
        }

        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Logger.debug("Failed to parse persist:root as JSON", context: "Migration")
            return nil
        }

        guard let settingsJson = root["settings"] as? String,
              let settingsData = settingsJson.data(using: .utf8)
        else {
            Logger.debug("Failed to extract settings from persist:root", context: "Migration")
            return nil
        }

        do {
            let settings = try JSONDecoder().decode(RNSettings.self, from: settingsData)
            Logger.debug(
                "Extracted RN settings: currency=\(settings.selectedCurrency ?? "nil"), language=\(settings.selectedLanguage ?? "nil")",
                context: "Migration"
            )
            return settings
        } catch {
            Logger.error("Failed to decode RN settings: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNMetadata(from mmkvData: [String: String]) -> RNMetadata? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else { return nil }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadataJson = root["metadata"] as? String,
              let metadataData = metadataJson.data(using: .utf8)
        else {
            return nil
        }

        do {
            let metadata = try JSONDecoder().decode(RNMetadata.self, from: metadataData)
            let tagCount = metadata.tags?.count ?? 0
            Logger.debug("Extracted RN metadata: \(tagCount) tagged txs", context: "Migration")
            return metadata
        } catch {
            Logger.error("Failed to decode RN metadata: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNWidgets(from mmkvData: [String: String]) -> RNWidgetsWithOptions? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else { return nil }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let widgetsJson = root["widgets"] as? String,
              let widgetsData = widgetsJson.data(using: .utf8)
        else {
            return nil
        }

        do {
            let widgets = try JSONDecoder().decode(RNWidgets.self, from: widgetsData)
            Logger.debug("Extracted RN widgets: sortOrder=\(widgets.sortOrder ?? [])", context: "Migration")

            var widgetOptions: [String: Data] = [:]
            if let widgetsDict = try? JSONSerialization.jsonObject(with: widgetsData) as? [String: Any] {
                widgetOptions = convertRNWidgetPreferences(widgetsDict)

                if widgetOptions.isEmpty, let nestedDict = widgetsDict["widgets"] as? [String: Any] {
                    widgetOptions = convertRNWidgetPreferences(nestedDict)
                }
            }

            return RNWidgetsWithOptions(widgets: widgets, widgetOptions: widgetOptions)
        } catch {
            Logger.error("Failed to decode RN widgets: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNTodos(from mmkvData: [String: String]) -> RNTodos? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else { return nil }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let todosJson = root["todos"] as? String,
              let todosData = todosJson.data(using: .utf8)
        else {
            return nil
        }

        do {
            let todos = try JSONDecoder().decode(RNTodos.self, from: todosData)
            let hideCount = todos.hide?.count ?? 0
            Logger.debug("Extracted RN todos: \(hideCount) hidden suggestions", context: "Migration")
            return todos
        } catch {
            Logger.error("Failed to decode RN todos: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNBlocktank(from mmkvData: [String: String]) -> (orders: [String], paidOrders: [String: String])? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else { return nil }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocktankJson = root["blocktank"] as? String,
              let blocktankData = blocktankJson.data(using: .utf8),
              let blocktankDict = try? JSONSerialization.jsonObject(with: blocktankData) as? [String: Any]
        else {
            return nil
        }

        var orderIds: [String] = []
        var paidOrdersMap: [String: String] = [:]

        if let orders = blocktankDict["orders"] as? [[String: Any]] {
            orderIds = orders.compactMap { $0["id"] as? String }
        }

        if let paidOrders = blocktankDict["paidOrders"] as? [String: String] {
            paidOrdersMap = paidOrders
        }

        if orderIds.isEmpty && paidOrdersMap.isEmpty {
            return nil
        }

        Logger.debug("Extracted RN blocktank: \(orderIds.count) orders, \(paidOrdersMap.count) paid orders", context: "Migration")
        return (orders: orderIds, paidOrders: paidOrdersMap)
    }

    func extractRNActivities(from mmkvData: [String: String]) -> [RNActivityItem]? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else { return nil }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let activityJson = root["activity"] as? String,
              let activityData = activityJson.data(using: .utf8)
        else {
            return nil
        }

        do {
            let activityState = try JSONDecoder().decode(RNActivityState.self, from: activityData)
            let items = activityState.items ?? []
            Logger.debug("Extracted \(items.count) RN activities", context: "Migration")
            return items
        } catch {
            Logger.error("Failed to decode RN activities: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNClosedChannels(from mmkvData: [String: String]) -> [RNChannel]? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else { return nil }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lightningJson = root["lightning"] as? String,
              let lightningData = lightningJson.data(using: .utf8)
        else {
            return nil
        }

        do {
            let lightningState = try JSONDecoder().decode(RNLightningState.self, from: lightningData)
            var closedChannels: [RNChannel] = []
            for (_, node) in lightningState.nodes ?? [:] {
                for (_, channels) in node.channels ?? [:] {
                    for (_, channel) in channels {
                        if channel.status == "closed" {
                            closedChannels.append(channel)
                        }
                    }
                }
            }

            Logger.debug("Extracted \(closedChannels.count) RN closed channels", context: "Migration")
            return closedChannels.isEmpty ? nil : closedChannels
        } catch {
            Logger.error("Failed to decode RN lightning state: \(error)", context: "Migration")
            return nil
        }
    }

    func extractRNWalletBackup(from mmkvData: [String: String]) -> (transfers: [String: String], boosts: [String: String])? {
        guard let rootJson = mmkvData["persist:root"],
              let jsonStart = rootJson.firstIndex(of: "{")
        else {
            return nil
        }

        let jsonString = String(rootJson[jsonStart...])
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let walletJson = root["wallet"] as? String,
              let walletData = walletJson.data(using: .utf8)
        else {
            return nil
        }

        func extractTransfers(_ transfers: [String: [RNTransfer]]?) -> [String: String] {
            var transferMap: [String: String] = [:]
            guard let transfers else { return transferMap }
            for (_, networkTransfers) in transfers {
                for transfer in networkTransfers {
                    if let txId = transfer.txId, let type = transfer.type {
                        transferMap[txId] = type
                    }
                }
            }
            return transferMap
        }

        func extractBoosts(_ boostedTxs: [String: [String: RNBoostedTransaction]]?) -> [String: String] {
            var boostMap: [String: String] = [:]
            guard let boostedTxs else { return boostMap }
            for (_, networkBoosts) in boostedTxs {
                for (parentTxId, boost) in networkBoosts {
                    if let childTxId = boost.childTransaction ?? boost.newTxId {
                        boostMap[parentTxId] = childTxId
                    }
                }
            }
            return boostMap
        }

        do {
            if let walletState = try? JSONDecoder().decode(RNWalletState.self, from: walletData),
               let wallets = walletState.wallets
            {
                var transferMap: [String: String] = [:]
                var boostMap: [String: String] = [:]

                for (_, walletData) in wallets {
                    transferMap.merge(extractTransfers(walletData.transfers)) { _, new in new }
                    boostMap.merge(extractBoosts(walletData.boostedTransactions)) { _, new in new }
                }

                if !transferMap.isEmpty || !boostMap.isEmpty {
                    return (transfers: transferMap, boosts: boostMap)
                }
            }

            let walletBackup = try JSONDecoder().decode(RNWalletBackup.self, from: walletData)
            let transferMap = extractTransfers(walletBackup.transfers)
            let boostMap = extractBoosts(walletBackup.boostedTransactions)

            if !transferMap.isEmpty || !boostMap.isEmpty {
                return (transfers: transferMap, boosts: boostMap)
            }

            return nil
        } catch {
            Logger.error("Failed to decode RN wallet backup: \(error)", context: "Migration")
            return nil
        }
    }

    func applyRNSettings(_ settings: RNSettings) {
        let defaults = UserDefaults.standard

        if let currency = settings.selectedCurrency {
            defaults.set(currency, forKey: "selectedCurrency")
        }
        if let language = settings.selectedLanguage {
            defaults.set(language, forKey: "selectedLanguageCode")
        }
        if let unit = settings.unit {
            let nativeValue = unit == "BTC" ? "Bitcoin" : "Fiat"
            defaults.set(nativeValue, forKey: "primaryDisplay")
        }
        if let denomination = settings.denomination {
            defaults.set(denomination, forKey: "bitcoinDisplayUnit")
        }
        if let hideBalance = settings.hideBalance {
            defaults.set(hideBalance, forKey: "hideBalance")
        }
        if let hideBalanceOnOpen = settings.hideBalanceOnOpen {
            defaults.set(hideBalanceOnOpen, forKey: "hideBalanceOnOpen")
        }
        if let swipeToHide = settings.enableSwipeToHideBalance {
            defaults.set(swipeToHide, forKey: "swipeBalanceToHide")
        }
        if let enableQuickpay = settings.enableQuickpay {
            defaults.set(enableQuickpay, forKey: "enableQuickpay")
        }
        if let quickpayAmount = settings.quickpayAmount {
            defaults.set(Double(quickpayAmount), forKey: "quickpayAmount")
        }
        if let readClipboard = settings.enableAutoReadClipboard {
            defaults.set(readClipboard, forKey: "readClipboard")
        }
        if let warnWhenSending = settings.enableSendAmountWarning {
            defaults.set(warnWhenSending, forKey: "warnWhenSendingOver100")
        }
        if let showWidgets = settings.showWidgets {
            defaults.set(showWidgets, forKey: "showWidgets")
        }
        if let showWidgetTitles = settings.showWidgetTitles {
            defaults.set(showWidgetTitles, forKey: "showWidgetTitles")
        }
        if let speed = settings.transactionSpeed {
            defaults.set(speed, forKey: "defaultTransactionSpeed")
        }
        if let coinSelectAuto = settings.coinSelectAuto {
            let method = coinSelectAuto ? "autopilot" : "manual"
            defaults.set(method, forKey: "coinSelectionMethod")
        }
        if let coinSelectPreference = settings.coinSelectPreference {
            defaults.set(coinSelectPreference, forKey: "coinSelectionAlgorithm")
        }
        if let requirePinForPayments = settings.pinForPayments {
            defaults.set(requirePinForPayments, forKey: "requirePinForPayments")
        }
        if let useBiometrics = settings.biometrics {
            defaults.set(useBiometrics, forKey: "useBiometrics")
        }
        if let pinOnLaunch = settings.pinOnLaunch {
            defaults.set(pinOnLaunch, forKey: "pinOnLaunch")
        }
        if let pinOnIdle = settings.pinOnIdle {
            defaults.set(pinOnIdle, forKey: "pinOnIdle")
        }
        if let seen = settings.quickpayIntroSeen {
            defaults.set(seen, forKey: "hasSeenQuickpayIntro")
        }
        if let seen = settings.shopIntroSeen {
            defaults.set(seen, forKey: "hasSeenShopIntro")
        }
        if let seen = settings.transferIntroSeen {
            defaults.set(seen, forKey: "hasSeenTransferIntro")
        }
        if let seen = settings.spendingIntroSeen {
            defaults.set(seen, forKey: "hasSeenTransferToSpendingIntro")
        }
        if let seen = settings.savingsIntroSeen {
            defaults.set(seen, forKey: "hasSeenTransferToSavingsIntro")
        }

        Logger.info("Applied RN settings to UserDefaults", context: "Migration")
    }

    func applyRNWidgets(_ widgetsWithOptions: RNWidgetsWithOptions) {
        let widgets = widgetsWithOptions.widgets
        let widgetOptions = widgetsWithOptions.widgetOptions

        if let sortOrder = widgets.sortOrder {
            let widgetTypeMap: [String: MigrationWidgetType] = [
                "price": .price,
                "news": .news,
                "blocks": .blocks,
                "weather": .weather,
                "facts": .facts,
                "calculator": .calculator,
            ]

            var savedWidgets: [MigrationSavedWidget] = []
            for widgetName in sortOrder {
                if let widgetType = widgetTypeMap[widgetName] {
                    let optionsData = widgetOptions[widgetName]
                    savedWidgets.append(MigrationSavedWidget(type: widgetType, optionsData: optionsData))
                }
            }

            if !savedWidgets.isEmpty {
                do {
                    let encodedData = try JSONEncoder().encode(savedWidgets)
                    UserDefaults.standard.set(encodedData, forKey: "savedWidgets")
                    UserDefaults.standard.synchronize()
                    let withOptions = savedWidgets.filter { $0.optionsData != nil }.count
                    Logger.info("Migrated \(savedWidgets.count) widgets (\(withOptions) with options)", context: "Migration")
                } catch {
                    Logger.error("Failed to encode widgets: \(error)", context: "Migration")
                }
            }
        }

        if let onboarded = widgets.onboardedWidgets {
            UserDefaults.standard.set(onboarded, forKey: "hasSeenWidgetsIntro")
        }
    }

    func applyRNTodos(_ todos: RNTodos) {
        // Map RN todo types to iOS suggestion IDs
        let mapping: [String: String] = [
            "backupSeedPhrase": "backupSeedPhrase",
            "buyBitcoin": "buyBitcoin",
            "lightning": "transferToSpending",
            "quickpay": "quickpay",
            "shop": "shop",
            "slashtagsProfile": "profile",
            "support": "support",
            "invite": "invite",
            "pin": "pin",
        ]

        guard let hide = todos.hide else { return }

        var dismissedIds: [String] = []
        for rnTodoType in hide.keys {
            if let iosSuggestionId = mapping[rnTodoType] {
                dismissedIds.append(iosSuggestionId)
            }
        }

        if !dismissedIds.isEmpty {
            let existing = UserDefaults.standard.stringArray(forKey: "dismissedSuggestions") ?? []
            let merged = Array(Set(existing + dismissedIds))
            UserDefaults.standard.set(merged, forKey: "dismissedSuggestions")
            Logger.info("Migrated \(dismissedIds.count) dismissed suggestions", context: "Migration")
        }
    }

    func applyRNActivities(_ items: [RNActivityItem]) async {
        var activities: [Activity] = []
        let now = UInt64(Date().timeIntervalSince1970)

        for item in items {
            guard item.activityType == "lightning" else { continue }

            let txType: BitkitCore.PaymentType = item.txType == "sent" ? .sent : .received
            let status: BitkitCore.PaymentState = switch item.status {
            case "successful", "succeeded": .succeeded
            case "failed": .failed
            default: .pending
            }

            let timestampSecs = UInt64(item.timestamp / 1000)
            let invoice = (item.address?.isEmpty == false) ? item.address! : "migrated:\(item.id)"

            let lightning = BitkitCore.LightningActivity(
                id: item.id,
                txType: txType,
                status: status,
                value: UInt64(item.value),
                fee: item.fee.map { UInt64($0) },
                invoice: invoice,
                message: item.message ?? "",
                timestamp: timestampSecs,
                preimage: item.preimage,
                createdAt: timestampSecs,
                updatedAt: timestampSecs,
                seenAt: now
            )
            activities.append(.lightning(lightning))
        }

        if !activities.isEmpty {
            do {
                try await CoreService.shared.activity.upsertList(activities)
                Logger.info("Migrated \(activities.count) lightning activities", context: "Migration")
            } catch {
                Logger.error("Failed to migrate activities: \(error)", context: "Migration")
            }
        }
    }

    func applyRNClosedChannels(_ channels: [RNChannel]) async {
        let now = UInt64(Date().timeIntervalSince1970)

        let closedChannels: [ClosedChannelDetails] = channels.compactMap { channel -> ClosedChannelDetails? in
            guard let fundingTxid = channel.funding_txid else { return nil }

            let closedAtSecs = channel.createdAt.map { UInt64($0 / 1000) } ?? now

            let outboundMsat = (channel.outbound_capacity_sat ?? 0) * 1000
            let inboundMsat = (channel.inbound_capacity_sat ?? 0) * 1000

            return ClosedChannelDetails(
                channelId: channel.channel_id,
                counterpartyNodeId: channel.counterparty_node_id ?? "",
                fundingTxoTxid: fundingTxid,
                fundingTxoIndex: 0,
                channelValueSats: channel.channel_value_satoshis ?? 0,
                closedAt: closedAtSecs,
                outboundCapacityMsat: outboundMsat,
                inboundCapacityMsat: inboundMsat,
                counterpartyUnspendablePunishmentReserve: channel.counterparty_unspendable_punishment_reserve ?? 0,
                unspendablePunishmentReserve: channel.unspendable_punishment_reserve ?? 0,
                forwardingFeeProportionalMillionths: 0,
                forwardingFeeBaseMsat: 0,
                channelName: "",
                channelClosureReason: channel.closureReason ?? "unknown"
            )
        }

        if !closedChannels.isEmpty {
            do {
                try await CoreService.shared.activity.upsertClosedChannelList(closedChannels)
                Logger.info("Migrated \(closedChannels.count) closed channels", context: "Migration")
            } catch {
                Logger.error("Failed to migrate closed channels: \(error)", context: "Migration")
            }
        }
    }

    func applyRNBlocktank(orderIds: [String], paidOrders: [String: String]) async {
        let allOrderIds = Array(Set(orderIds + Array(paidOrders.keys)))

        guard !allOrderIds.isEmpty else { return }

        do {
            let fetchedOrders = try await CoreService.shared.blocktank.orders(orderIds: allOrderIds, filter: nil, refresh: true)
            if !fetchedOrders.isEmpty {
                try await CoreService.shared.blocktank.upsertOrdersList(fetchedOrders)
                Logger.info("Upserted \(fetchedOrders.count) Blocktank orders", context: "Migration")
            }

            if !paidOrders.isEmpty {
                await createTransfersForPaidOrders(paidOrdersMap: paidOrders, orders: fetchedOrders)
            }
        } catch {
            Logger.warn("Failed to fetch and upsert Blocktank orders: \(error)", context: "Migration")
        }
    }

    func migrateMMKVData() async {
        guard let mmkvData = loadRNMmkvData() else {
            Logger.debug("No MMKV data to migrate", context: "Migration")
            return
        }

        if let activities = extractRNActivities(from: mmkvData) {
            let lightningCount = activities.filter { $0.activityType == "lightning" }.count
            Logger.info("Found \(activities.count) activities (\(lightningCount) lightning to migrate)", context: "Migration")
            await applyRNActivities(activities)
        } else {
            Logger.debug("No activities found in MMKV", context: "Migration")
        }

        if let closedChannels = extractRNClosedChannels(from: mmkvData) {
            Logger.info("Found \(closedChannels.count) closed channels to migrate", context: "Migration")
            await applyRNClosedChannels(closedChannels)
        } else {
            Logger.debug("No closed channels found in MMKV", context: "Migration")
        }

        if let settings = extractRNSettings(from: mmkvData) {
            Logger.info("Migrating settings", context: "Migration")
            applyRNSettings(settings)
        } else {
            Logger.warn("Failed to extract settings from MMKV", context: "Migration")
        }

        if let metadata = extractRNMetadata(from: mmkvData) {
            Logger.info("Migrating metadata", context: "Migration")
            await applyAllMetadata(metadata)
        } else {
            Logger.debug("No metadata found in MMKV", context: "Migration")
        }

        if let widgets = extractRNWidgets(from: mmkvData) {
            Logger.info("Migrating widgets", context: "Migration")
            applyRNWidgets(widgets)
        } else {
            Logger.debug("No widgets found in MMKV", context: "Migration")
        }

        if let todos = extractRNTodos(from: mmkvData) {
            Logger.info("Migrating todos/dismissed suggestions", context: "Migration")
            applyRNTodos(todos)
        } else {
            Logger.debug("No todos found in MMKV", context: "Migration")
        }

        if let blocktank = extractRNBlocktank(from: mmkvData) {
            Logger.info("Migrating blocktank orders", context: "Migration")
            await applyRNBlocktank(orderIds: blocktank.orders, paidOrders: blocktank.paidOrders)
        } else {
            Logger.debug("No blocktank data found in MMKV", context: "Migration")
        }

        UserDefaults.standard.set("", forKey: "onchainAddress")

        Logger.info("MMKV data migration completed", context: "Migration")
    }

    func reapplyMetadataAfterSync() async {
        // Handle MMKV (local) migration data
        if hasRNMmkvData(), let mmkvData = loadRNMmkvData() {
            if let activities = extractRNActivities(from: mmkvData) {
                await applyOnchainMetadata(activities)
            }

            // Extract and apply wallet backup data (transfers and boosts)
            if let walletBackup = extractRNWalletBackup(from: mmkvData) {
                if !walletBackup.transfers.isEmpty {
                    Logger.info("Applying \(walletBackup.transfers.count) local transfer markers", context: "Migration")
                    await applyRemoteTransfers(walletBackup.transfers)
                }
                if !walletBackup.boosts.isEmpty {
                    Logger.info("Applying \(walletBackup.boosts.count) local boost markers", context: "Migration")
                    await applyBoostTransactions(walletBackup.boosts)
                }
            }

            if let metadata = extractRNMetadata(from: mmkvData) {
                Logger.info("Re-applying MMKV metadata after sync", context: "Migration")
                await applyAllMetadata(metadata)
            }
        }

        // Handle remote backup data (for on-chain timestamps from RN backup)
        if let remoteActivities = pendingRemoteActivityData {
            Logger.info("Re-applying remote backup metadata after sync", context: "Migration")
            await applyOnchainMetadata(remoteActivities)
            pendingRemoteActivityData = nil
        }

        // Handle remote backup transfers (mark on-chain txs as transfers)
        if let transfers = pendingRemoteTransfers {
            Logger.info("Applying \(transfers.count) remote transfer markers", context: "Migration")
            await applyRemoteTransfers(transfers)
            pendingRemoteTransfers = nil
        }

        // Handle remote backup boosts (apply boostTxIds to activities)
        if let boosts = pendingRemoteBoosts {
            Logger.info("Applying \(boosts.count) remote boost markers", context: "Migration")
            await applyBoostTransactions(boosts)
            pendingRemoteBoosts = nil
        }

        // Apply stored metadata (all tags after activities are imported)
        if let metadata = pendingRemoteMetadata {
            Logger.info("Applying stored metadata after sync", context: "Migration")
            await applyAllMetadata(metadata)
            pendingRemoteMetadata = nil
        }

        // Handle remote backup paid orders (create transfers for pending channel orders)
        if let paidOrders = pendingRemotePaidOrders {
            Logger.info("Applying \(paidOrders.count) remote paid orders", context: "Migration")
            await applyRemotePaidOrders(paidOrders)
            pendingRemotePaidOrders = nil
        }
    }

    private func applyRemoteTransfers(_ transfers: [String: String]) async {
        var applied = 0

        for (txId, channelId) in transfers {
            guard var onchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txId) else {
                continue
            }

            onchain.isTransfer = true
            onchain.channelId = channelId

            do {
                try await CoreService.shared.activity.update(id: onchain.id, activity: .onchain(onchain))
                applied += 1
            } catch {
                Logger.error("Failed to mark tx \(txId) as transfer: \(error)", context: "Migration")
            }
        }

        Logger.info("Applied \(applied)/\(transfers.count) transfer markers", context: "Migration")
    }

    private func applyRemotePaidOrders(_ paidOrders: [String: String]) async {
        let orderIds = Array(paidOrders.keys)
        guard !orderIds.isEmpty else { return }

        do {
            let fetchedOrders = try await CoreService.shared.blocktank.orders(orderIds: orderIds, filter: nil, refresh: true)
            if !fetchedOrders.isEmpty {
                try await CoreService.shared.blocktank.upsertOrdersList(fetchedOrders)
                Logger.info("Upserted \(fetchedOrders.count) Blocktank orders from remote backup", context: "Migration")
            }
            await createTransfersForPaidOrders(paidOrdersMap: paidOrders, orders: fetchedOrders)
        } catch {
            Logger.warn("Failed to fetch Blocktank orders: \(error)", context: "Migration")
        }
    }

    private func applyBoostTransactions(_ boosts: [String: String]) async {
        var applied = 0

        for (oldTxId, newTxId) in boosts {
            let oldOnchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: oldTxId)
            let newOnchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: newTxId)

            if let oldOnchain, var newOnchain {
                var parentOnchain = oldOnchain
                if !parentOnchain.boostTxIds.contains(newTxId) {
                    parentOnchain.boostTxIds.append(newTxId)
                }
                parentOnchain.isBoosted = true

                newOnchain.isBoosted = false
                newOnchain.boostTxIds.removeAll { $0 == oldTxId }

                do {
                    try await CoreService.shared.activity.update(id: parentOnchain.id, activity: .onchain(parentOnchain))
                    try await CoreService.shared.activity.update(id: newOnchain.id, activity: .onchain(newOnchain))
                    applied += 1
                } catch {
                    Logger.error("Failed to apply CPFP boost for parent \(oldTxId) / child \(newTxId): \(error)", context: "Migration")
                }
            } else if var newOnchain {
                if !newOnchain.boostTxIds.contains(oldTxId) {
                    newOnchain.boostTxIds.append(oldTxId)
                }
                newOnchain.isBoosted = true

                do {
                    try await CoreService.shared.activity.update(id: newOnchain.id, activity: .onchain(newOnchain))
                    applied += 1
                } catch {
                    Logger.error("Failed to apply RBF boost for tx \(newTxId): \(error)", context: "Migration")
                }
            }
        }

        Logger.info("Applied \(applied)/\(boosts.count) boost markers", context: "Migration")
    }

    private func applyAllMetadata(_ metadata: RNMetadata) async {
        if let tags = metadata.tags, !tags.isEmpty {
            await applyPendingTags(tags)
        }

        if let lastUsedTags = metadata.lastUsedTags {
            UserDefaults.standard.set(lastUsedTags, forKey: "lastUsedTags")
        }
    }

    private func applyPendingTags(_ tags: [String: [String]]) async {
        var applied = 0
        for (activityId, tagList) in tags {
            do {
                if let onchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: activityId) {
                    try await CoreService.shared.activity.upsertTags([
                        ActivityTags(activityId: onchain.id, tags: tagList),
                    ])
                    applied += 1
                } else if let activity = try? await CoreService.shared.activity.getActivity(id: activityId),
                          case .lightning = activity
                {
                    try await CoreService.shared.activity.upsertTags([
                        ActivityTags(activityId: activityId, tags: tagList),
                    ])
                    applied += 1
                }
            } catch {
                Logger.error("Failed to apply pending tag for \(activityId): \(error)", context: "Migration")
            }
        }
        Logger.info("Applied \(applied)/\(tags.count) pending tags", context: "Migration")
    }

    private func applyOnchainMetadata(_ items: [RNActivityItem]) async {
        let onchainItems = items.filter { $0.activityType == "onchain" }
        var updatedCount = 0
        var createdCount = 0

        for item in onchainItems {
            guard let txId = item.txId ?? (item.id.isEmpty ? nil : item.id) else {
                continue
            }

            // Try to get existing activity (synced by LDK)
            if var onchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txId) {
                // Activity exists, update metadata
                if item.timestamp > 0 {
                    onchain.timestamp = UInt64(item.timestamp / 1000)
                }
                if let confirmTs = item.confirmTimestamp, confirmTs > 0 {
                    onchain.confirmTimestamp = UInt64(confirmTs / 1000)
                }
                if item.isTransfer == true {
                    onchain.isTransfer = true
                    onchain.channelId = item.channelId
                    onchain.transferTxId = item.transferTxId
                }

                if let boostedParents = item.boostedParents, !boostedParents.isEmpty {
                    await applyBoostedParents(boostedParents, childTxId: txId)
                    onchain.isBoosted = false
                    onchain.boostTxIds.removeAll { boostedParents.contains($0) }
                } else if item.isBoosted == true {
                    onchain.isBoosted = true
                }

                if let feeRate = item.feeRate, feeRate > 0 {
                    onchain.feeRate = UInt64(feeRate)
                }

                // Preserve higher value from backup (handles mixed input txs with unsupported addresses)
                let backupValue = UInt64(item.value)
                if backupValue > onchain.value {
                    onchain.value = backupValue
                }

                // Preserve higher fee from backup
                if let backupFee = item.fee, UInt64(backupFee) > onchain.fee {
                    onchain.fee = UInt64(backupFee)
                }

                if let address = item.address, !address.isEmpty {
                    onchain.address = address
                }

                do {
                    try await CoreService.shared.activity.update(id: onchain.id, activity: .onchain(onchain))
                    updatedCount += 1
                } catch {
                    Logger.error("Failed to update onchain metadata for \(txId): \(error)", context: "Migration")
                }
            } else {
                let timestampSecs = UInt64(item.timestamp / 1000)
                let now = UInt64(Date().timeIntervalSince1970)
                let activityTimestamp = timestampSecs > 0 ? timestampSecs : now

                let onchain = BitkitCore.OnchainActivity(
                    id: item.id,
                    txType: item.txType == "sent" ? .sent : .received,
                    txId: txId,
                    value: UInt64(item.value),
                    fee: item.fee.map { UInt64($0) } ?? 0,
                    feeRate: item.feeRate.map { UInt64($0) } ?? 1,
                    address: item.address ?? "",
                    confirmed: item.confirmed ?? false,
                    timestamp: activityTimestamp,
                    isBoosted: item.isBoosted ?? false,
                    boostTxIds: [],
                    isTransfer: item.isTransfer ?? false,
                    doesExist: item.exists ?? true,
                    confirmTimestamp: item.confirmTimestamp.map { UInt64($0 / 1000) },
                    channelId: item.channelId,
                    transferTxId: item.transferTxId,
                    createdAt: activityTimestamp,
                    updatedAt: activityTimestamp,
                    seenAt: now
                )

                do {
                    try await CoreService.shared.activity.upsert(.onchain(onchain))
                    createdCount += 1

                    if let boostedParents = item.boostedParents, !boostedParents.isEmpty {
                        await applyBoostedParents(boostedParents, childTxId: txId)
                    }
                } catch {
                    Logger.error("Failed to import onchain activity from backup \(txId): \(error)", context: "Migration")
                }
            }
        }

        if updatedCount > 0 || createdCount > 0 {
            Logger.info(
                "Applied metadata to \(updatedCount) onchain activities, imported \(createdCount) from backup",
                context: "Migration"
            )
        }
    }

    private func applyBoostedParents(_ boostedParents: [String], childTxId: String) async {
        for parentTxId in boostedParents {
            if var parentOnchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: parentTxId) {
                if !parentOnchain.boostTxIds.contains(childTxId) {
                    parentOnchain.boostTxIds.append(childTxId)
                }
                parentOnchain.isBoosted = true
                do {
                    try await CoreService.shared.activity.update(id: parentOnchain.id, activity: .onchain(parentOnchain))
                } catch {
                    Logger.error("Failed to mark parent \(parentTxId) as boosted for CPFP: \(error)", context: "Migration")
                }
            }
        }
    }

    private func convertRNWidgetPreferences(_ widgetsDict: [String: Any]) -> [String: Data] {
        var result: [String: Data] = [:]

        func getBool(from dict: [String: Any], key: String, fallbackKey: String? = nil, defaultValue: Bool) -> Bool {
            let keys = fallbackKey != nil ? [key, fallbackKey!] : [key]
            for k in keys {
                if let val = dict[k] as? Bool { return val }
                if let val = dict[k] as? Int { return val != 0 }
                if let val = dict[k] as? NSNumber { return val.boolValue }
            }
            return defaultValue
        }
        let pricePrefs = (widgetsDict["pricePreferences"] as? [String: Any])
            ?? (widgetsDict["price"] as? [String: Any])
        if let prefs = pricePrefs {
            var selectedPairs = ["BTC/USD"]
            if let pairsArray = (prefs["pairs"] as? [String]) ?? (prefs["enabledPairs"] as? [String]) {
                selectedPairs = pairsArray.map { $0.replacingOccurrences(of: "_", with: "/") }
                if selectedPairs.isEmpty { selectedPairs = ["BTC/USD"] }
            }
            let rnPeriod = prefs["period"] as? String ?? "1D"
            let periodMap = ["ONE_DAY": "1D", "ONE_WEEK": "1W", "ONE_MONTH": "1M", "ONE_YEAR": "1Y"]
            let iosPeriodRaw = periodMap[rnPeriod] ?? rnPeriod
            let period = MigrationGraphPeriod(rawValue: iosPeriodRaw) ?? .oneDay
            let options = MigrationPriceWidgetOptions(
                selectedPairs: selectedPairs,
                selectedPeriod: period,
                showSource: getBool(from: prefs, key: "showSource", defaultValue: false)
            )
            if let data = try? JSONEncoder().encode(options) {
                result["price"] = data
            }
        }

        let weatherPrefs = (widgetsDict["weatherPreferences"] as? [String: Any])
            ?? (widgetsDict["weather"] as? [String: Any])
        if let prefs = weatherPrefs {
            let options = MigrationWeatherWidgetOptions(
                showStatus: getBool(from: prefs, key: "showTitle", fallbackKey: "showStatus", defaultValue: true),
                showText: getBool(from: prefs, key: "showDescription", fallbackKey: "showText", defaultValue: false),
                showMedian: getBool(from: prefs, key: "showCurrentFee", fallbackKey: "showMedian", defaultValue: false),
                showNextBlockFee: getBool(from: prefs, key: "showNextBlockFee", defaultValue: false)
            )
            if let data = try? JSONEncoder().encode(options) {
                result["weather"] = data
            }
        }

        let newsPrefs = (widgetsDict["headlinePreferences"] as? [String: Any])
            ?? (widgetsDict["headline"] as? [String: Any])
            ?? (widgetsDict["news"] as? [String: Any])
        if let prefs = newsPrefs {
            let options = MigrationNewsWidgetOptions(
                showDate: getBool(from: prefs, key: "showDate", fallbackKey: "showTime", defaultValue: true),
                showTitle: getBool(from: prefs, key: "showTitle", defaultValue: true),
                showSource: getBool(from: prefs, key: "showSource", defaultValue: true)
            )
            if let data = try? JSONEncoder().encode(options) {
                result["news"] = data
            }
        }

        let blocksPrefs = (widgetsDict["blocksPreferences"] as? [String: Any])
            ?? (widgetsDict["blocks"] as? [String: Any])
        if let prefs = blocksPrefs {
            let options = MigrationBlocksWidgetOptions(
                height: getBool(from: prefs, key: "height", fallbackKey: "showBlock", defaultValue: true),
                time: getBool(from: prefs, key: "time", fallbackKey: "showTime", defaultValue: true),
                date: getBool(from: prefs, key: "date", fallbackKey: "showDate", defaultValue: true),
                transactionCount: getBool(from: prefs, key: "transactionCount", fallbackKey: "showTransactions", defaultValue: false),
                size: getBool(from: prefs, key: "size", fallbackKey: "showSize", defaultValue: false),
                weight: getBool(from: prefs, key: "weight", defaultValue: false),
                difficulty: getBool(from: prefs, key: "difficulty", defaultValue: false),
                hash: getBool(from: prefs, key: "hash", defaultValue: false),
                merkleRoot: getBool(from: prefs, key: "merkleRoot", defaultValue: false),
                showSource: getBool(from: prefs, key: "showSource", defaultValue: false)
            )
            if let data = try? JSONEncoder().encode(options) {
                result["blocks"] = data
            }
        }

        let factsPrefs = (widgetsDict["factsPreferences"] as? [String: Any])
            ?? (widgetsDict["facts"] as? [String: Any])
        if let prefs = factsPrefs {
            let options = MigrationFactsWidgetOptions(
                showSource: getBool(from: prefs, key: "showSource", defaultValue: false)
            )
            if let data = try? JSONEncoder().encode(options) {
                result["facts"] = data
            }
        }

        return result
    }
}

// MARK: - RN Remote Backup Restore

extension MigrationsService {
    private func normalizePassphrase(_ passphrase: String?) -> String? {
        passphrase?.isEmpty == true ? nil : passphrase
    }

    func hasRNRemoteBackup(mnemonic: String, passphrase: String?) async -> Bool {
        do {
            let effectivePassphrase = normalizePassphrase(passphrase)
            RNBackupClient.shared.reset()
            try await RNBackupClient.shared.setup(mnemonic: mnemonic, passphrase: effectivePassphrase)
            return try await RNBackupClient.shared.hasBackup()
        } catch {
            Logger.error("Failed to check RN remote backup: \(error)", context: "Migration")
            return false
        }
    }

    func restoreFromRNRemoteBackup(mnemonic: String, passphrase: String?) async throws {
        let effectivePassphrase = normalizePassphrase(passphrase)
        try await RNBackupClient.shared.setup(mnemonic: mnemonic, passphrase: effectivePassphrase)

        isRestoringFromRNRemoteBackup = true
        Logger.info("Starting RN remote backup restore", context: "Migration")

        clearPinSettings()

        // Fetch LDK data (channel_manager and channel_monitors)
        await fetchRNRemoteLdkData()

        async let settingsData = RNBackupClient.shared.retrieve(label: "bitkit_settings", fileGroup: "bitkit")
        async let widgetsData = RNBackupClient.shared.retrieve(label: "bitkit_widgets", fileGroup: "bitkit")
        async let activityData = RNBackupClient.shared.retrieve(label: "bitkit_lightning_activity", fileGroup: "bitkit")
        async let metadataData = RNBackupClient.shared.retrieve(label: "bitkit_metadata", fileGroup: "bitkit")
        async let walletData = RNBackupClient.shared.retrieve(label: "bitkit_wallet", fileGroup: "bitkit")
        async let blocktankData = RNBackupClient.shared.retrieve(label: "bitkit_blocktank_orders", fileGroup: "bitkit")

        if let settings = try? await settingsData {
            try await applyRNRemoteSettings(settings)
        } else {
            Logger.warn("Failed to retrieve bitkit_settings from remote backup", context: "Migration")
        }

        if let widgets = try? await widgetsData {
            try await applyRNRemoteWidgets(widgets)
        } else {
            Logger.warn("Failed to retrieve bitkit_widgets from remote backup", context: "Migration")
        }

        if let activity = try? await activityData {
            try await applyRNRemoteActivity(activity)
        } else {
            Logger.warn("Failed to retrieve bitkit_lightning_activity from remote backup", context: "Migration")
        }

        if let metadata = try? await metadataData {
            try await applyRNRemoteMetadata(metadata)
        } else {
            Logger.warn("Failed to retrieve bitkit_metadata from remote backup", context: "Migration")
        }

        if let wallet = try? await walletData {
            try await applyRNRemoteWallet(wallet)
        } else {
            Logger.warn("Failed to retrieve bitkit_wallet from remote backup", context: "Migration")
        }

        if let blocktank = try? await blocktankData {
            try await applyRNRemoteBlocktank(blocktank)
        } else {
            Logger.warn("Failed to retrieve bitkit_blocktank_orders from remote backup", context: "Migration")
        }

        Logger.info("RN remote backup restore completed", context: "Migration")
    }

    private func fetchRNRemoteLdkData() async {
        do {
            let files = try await RNBackupClient.shared.listFiles(fileGroup: "ldk")

            guard let managerData = try? await RNBackupClient.shared.retrieve(label: "channel_manager", fileGroup: "ldk") else {
                Logger.debug("No channel_manager found in remote LDK backup", context: "Migration")
                return
            }

            let monitors = await withTaskGroup(of: Data?.self) { group in
                var results: [Data] = []
                for monitorFile in files.channel_monitors {
                    group.addTask {
                        let channelId = monitorFile.replacingOccurrences(of: ".bin", with: "")
                        return try? await RNBackupClient.shared.retrieveChannelMonitor(channelId: channelId)
                    }
                }
                for await monitor in group {
                    if let monitor {
                        results.append(monitor)
                    }
                }
                return results
            }

            if !monitors.isEmpty {
                pendingChannelMigration = PendingChannelMigration(
                    channelManager: managerData,
                    channelMonitors: monitors
                )
                Logger.info("Prepared \(monitors.count) channel monitors for migration", context: "Migration")
            }
        } catch {
            Logger.error("Failed to fetch remote LDK data: \(error)", context: "Migration")
        }
    }

    private func applyRNRemoteSettings(_ data: Data) async throws {
        struct BackupEnvelope: Codable {
            let data: RNSettings
        }

        guard let json = try? JSONDecoder().decode(BackupEnvelope.self, from: data) else {
            Logger.warn("Failed to decode RN remote settings backup", context: "Migration")
            return
        }

        var settings = json.data
        settings.pinForPayments = nil
        settings.biometrics = nil
        settings.pinOnLaunch = nil
        settings.pinOnIdle = nil
        applyRNSettings(settings)
    }

    private func applyRNRemoteWidgets(_ data: Data) async throws {
        struct BackupEnvelope: Codable {
            let data: RNWidgets
        }

        guard let json = try? JSONDecoder().decode(BackupEnvelope.self, from: data) else {
            Logger.warn("Failed to decode RN remote widgets backup", context: "Migration")
            return
        }

        var widgetOptions: [String: Data] = [:]
        if let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = rawDict["data"] as? [String: Any]
        {
            widgetOptions = convertRNWidgetPreferences(dataDict)

            if widgetOptions.isEmpty, let nestedDict = dataDict["widgets"] as? [String: Any] {
                widgetOptions = convertRNWidgetPreferences(nestedDict)
            }
        }

        let widgetsWithOptions = RNWidgetsWithOptions(widgets: json.data, widgetOptions: widgetOptions)
        applyRNWidgets(widgetsWithOptions)
    }

    private func applyRNRemoteMetadata(_ data: Data) async throws {
        struct BackupEnvelope: Codable {
            let data: RNMetadata
        }

        guard let json = try? JSONDecoder().decode(BackupEnvelope.self, from: data) else {
            Logger.warn("Failed to decode RN remote metadata backup", context: "Migration")
            return
        }

        // Store metadata for application after sync (on-chain activities don't exist yet)
        pendingRemoteMetadata = json.data
    }

    private func applyRNRemoteActivity(_ data: Data) async throws {
        struct ActivityItem: Codable {
            var id: String
            var activityType: String
            var txType: String
            var txId: String?
            var value: Int64
            var fee: Int64?
            var feeRate: Int64?
            var address: String?
            var confirmed: Bool?
            var timestamp: Int64
            var isBoosted: Bool?
            var isTransfer: Bool?
            var exists: Bool?
            var confirmTimestamp: Int64?
            var channelId: String?
            var transferTxId: String?
            var status: String?
            var message: String?
            var preimage: String?
            var boostedParents: [String]?
        }

        struct BackupEnvelope: Codable {
            let data: [ActivityItem]
        }

        guard let json = try? JSONDecoder().decode(BackupEnvelope.self, from: data) else {
            Logger.warn("Failed to decode RN remote activity backup", context: "Migration")
            return
        }

        let items: [RNActivityItem] = json.data.map { item in
            RNActivityItem(
                id: item.id,
                activityType: item.activityType,
                txType: item.txType,
                txId: item.txId,
                value: item.value,
                fee: item.fee,
                feeRate: item.feeRate,
                address: item.address,
                confirmed: item.confirmed,
                timestamp: item.timestamp,
                isBoosted: item.isBoosted,
                isTransfer: item.isTransfer,
                exists: item.exists,
                confirmTimestamp: item.confirmTimestamp,
                channelId: item.channelId,
                transferTxId: item.transferTxId,
                status: item.status,
                message: item.message,
                preimage: item.preimage,
                boostedParents: item.boostedParents
            )
        }

        // Store for later reapplication after sync (for on-chain timestamps)
        pendingRemoteActivityData = items

        await applyRNActivities(items)
    }

    private func applyRNRemoteWallet(_ data: Data) async throws {
        struct BackupEnvelope: Codable {
            let data: RNWalletBackup
        }

        guard let json = try? JSONDecoder().decode(BackupEnvelope.self, from: data) else {
            Logger.warn("Failed to decode RN remote wallet backup", context: "Migration")
            return
        }

        // Store transfers for later application (to mark on-chain txs as transfers)
        if let transfers = json.data.transfers {
            var transferMap: [String: String] = [:]
            var totalTransfersFound = 0
            for (_, networkTransfers) in transfers {
                totalTransfersFound += networkTransfers.count
                for transfer in networkTransfers {
                    if let txId = transfer.txId, let type = transfer.type {
                        // type contains the channelId for transfer identification
                        transferMap[txId] = type
                    }
                }
            }
            Logger.info("Found \(totalTransfersFound) transfers in backup, \(transferMap.count) with valid txId/type", context: "Migration")
            if !transferMap.isEmpty {
                pendingRemoteTransfers = transferMap
            }
        } else {
            Logger.debug("No transfers found in RN remote wallet backup", context: "Migration")
        }

        if let boostedTxs = json.data.boostedTransactions {
            var boostMap: [String: String] = [:]
            for (_, networkBoosts) in boostedTxs {
                for (oldTxId, boost) in networkBoosts {
                    if let childTxId = boost.childTransaction ?? boost.newTxId {
                        boostMap[oldTxId] = childTxId
                    }
                }
            }
            Logger.info("Found \(boostMap.count) boosted transactions in remote backup", context: "Migration")
            if !boostMap.isEmpty {
                pendingRemoteBoosts = boostMap
            }
        } else {
            Logger.debug("No boosted transactions found in RN remote wallet backup", context: "Migration")
        }
    }

    private func applyRNRemoteBlocktank(_ data: Data) async throws {
        struct BlocktankOrder: Codable {
            var id: String
            var state: String?
            var lspBalanceSat: UInt64?
            var clientBalanceSat: UInt64?
            var channelExpiryWeeks: Int?
            var createdAt: String?
        }

        struct BlocktankBackup: Codable {
            var orders: [BlocktankOrder]?
        }

        struct BackupEnvelope: Codable {
            let data: BlocktankBackup
        }

        guard let json = try? JSONDecoder().decode(BackupEnvelope.self, from: data) else {
            Logger.warn("Failed to decode RN remote blocktank backup", context: "Migration")
            return
        }

        var orderIds: [String] = []

        if let orders = json.data.orders {
            orderIds.append(contentsOf: orders.map(\.id))
        }

        // paidOrders is a map of orderId -> txId
        var paidOrdersMap: [String: String] = [:]
        if let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = rawDict["data"] as? [String: Any],
           let paidOrders = dataDict["paidOrders"] as? [String: String]
        {
            paidOrdersMap = paidOrders
            orderIds.append(contentsOf: paidOrders.keys)
            Logger.info("Found \(paidOrders.count) paid orders in blocktank backup", context: "Migration")
        }

        // Store paid orders for processing after wallet starts (CoreService not ready yet during restore)
        if !paidOrdersMap.isEmpty {
            pendingRemotePaidOrders = paidOrdersMap
        }
    }

    private func createTransfersForPaidOrders(paidOrdersMap: [String: String], orders: [IBtOrder]) async {
        let now = UInt64(Date().timeIntervalSince1970)
        var transfers: [Transfer] = []

        for (orderId, txId) in paidOrdersMap {
            guard let order = orders.first(where: { $0.id == orderId }) else {
                Logger.warn("Paid order \(orderId) not found in fetched orders", context: "Migration")
                continue
            }

            if order.state2 == .executed {
                continue
            }

            let transfer = Transfer(
                id: txId,
                type: .toSpending,
                amountSats: order.clientBalanceSat + order.feeSat,
                channelId: nil,
                fundingTxId: nil,
                lspOrderId: orderId,
                isSettled: false,
                createdAt: now,
                settledAt: nil
            )
            transfers.append(transfer)
        }

        if !transfers.isEmpty {
            do {
                try TransferStorage.shared.upsertList(transfers)
                Logger.info("Created \(transfers.count) transfers for paid Blocktank orders", context: "Migration")
            } catch {
                Logger.error("Failed to create transfers for paid orders: \(error)", context: "Migration")
            }
        }
    }
}
