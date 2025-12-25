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
    var comments: [String: String]?
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

    var pendingChannelMigration: PendingChannelMigration?

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
            let commentCount = metadata.comments?.count ?? 0
            Logger.debug("Extracted RN metadata: \(tagCount) tagged txs, \(commentCount) comments", context: "Migration")
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

    func applyRNMetadata(_ metadata: RNMetadata) async {
        if let tags = metadata.tags {
            for (txId, tagList) in tags {
                do {
                    var activityId = txId
                    if let onchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txId) {
                        activityId = onchain.id
                    }
                    try await CoreService.shared.activity.upsertTags([
                        ActivityTags(activityId: activityId, tags: tagList),
                    ])
                } catch {
                    Logger.error("Failed to migrate tags for \(txId): \(error)", context: "Migration")
                }
            }
            Logger.info("Migrated \(tags.count) activity tags", context: "Migration")
        }

        if let lastUsedTags = metadata.lastUsedTags {
            UserDefaults.standard.set(lastUsedTags, forKey: "lastUsedTags")
        }

        if let comments = metadata.comments, !comments.isEmpty {
            var existingComments = UserDefaults.standard.dictionary(forKey: "activityComments") as? [String: String] ?? [:]
            for (txId, comment) in comments {
                var activityId = txId
                if let onchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txId) {
                    activityId = onchain.id
                }
                existingComments[activityId] = comment
            }
            UserDefaults.standard.set(existingComments, forKey: "activityComments")
            Logger.info("Migrated \(comments.count) activity comments", context: "Migration")
        }
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
            await applyRNMetadata(metadata)
        } else {
            Logger.debug("No metadata found in MMKV", context: "Migration")
        }

        if let widgets = extractRNWidgets(from: mmkvData) {
            Logger.info("Migrating widgets", context: "Migration")
            applyRNWidgets(widgets)
        } else {
            Logger.debug("No widgets found in MMKV", context: "Migration")
        }

        UserDefaults.standard.set("", forKey: "onchainAddress")

        Logger.info("MMKV data migration completed", context: "Migration")
    }

    func reapplyMetadataAfterSync() async {
        guard hasRNMmkvData(), let mmkvData = loadRNMmkvData() else {
            return
        }

        if let metadata = extractRNMetadata(from: mmkvData) {
            Logger.info("Re-applying metadata after sync", context: "Migration")
            await applyRNMetadata(metadata)
        }

        if let activities = extractRNActivities(from: mmkvData) {
            await applyOnchainMetadata(activities)
        }
    }

    private func applyOnchainMetadata(_ items: [RNActivityItem]) async {
        let onchainItems = items.filter { $0.activityType == "onchain" }
        for item in onchainItems {
            guard let txId = item.txId ?? (item.id.isEmpty ? nil : item.id),
                  var onchain = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txId)
            else {
                continue
            }

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

            do {
                try await CoreService.shared.activity.update(id: onchain.id, activity: .onchain(onchain))
            } catch {
                Logger.error("Failed to update onchain metadata for \(txId): \(error)", context: "Migration")
            }
        }

        if !onchainItems.isEmpty {
            Logger.info("Applied metadata to \(onchainItems.count) onchain activities", context: "Migration")
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
