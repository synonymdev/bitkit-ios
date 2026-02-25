import BitkitCore
import Foundation

// MARK: - Backup Payload Models

struct WalletBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let transfers: [Transfer]
}

struct MetadataBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let tagMetadata: [PreActivityMetadata]
    let cache: AppCacheData
}

struct AppCacheData: Codable {
    let hasSeenContactsIntro: Bool
    let hasSeenProfileIntro: Bool
    let hasSeenNotificationsIntro: Bool
    let hasSeenQuickpayIntro: Bool
    let hasSeenShopIntro: Bool
    let hasSeenTransferIntro: Bool
    let hasSeenTransferToSpendingIntro: Bool
    let hasSeenTransferToSavingsIntro: Bool
    let hasSeenWidgetsIntro: Bool
    let hasDismissedWidgetsOnboardingHint: Bool
    let appUpdateIgnoreTimestamp: TimeInterval
    let backupIgnoreTimestamp: TimeInterval
    let highBalanceIgnoreCount: Int
    let highBalanceIgnoreTimestamp: TimeInterval
    let dismissedSuggestions: [String]
    let lastUsedTags: [String]

    init(
        hasSeenContactsIntro: Bool,
        hasSeenProfileIntro: Bool,
        hasSeenNotificationsIntro: Bool,
        hasSeenQuickpayIntro: Bool,
        hasSeenShopIntro: Bool,
        hasSeenTransferIntro: Bool,
        hasSeenTransferToSpendingIntro: Bool,
        hasSeenTransferToSavingsIntro: Bool,
        hasSeenWidgetsIntro: Bool,
        hasDismissedWidgetsOnboardingHint: Bool,
        appUpdateIgnoreTimestamp: TimeInterval,
        backupIgnoreTimestamp: TimeInterval,
        highBalanceIgnoreCount: Int,
        highBalanceIgnoreTimestamp: TimeInterval,
        dismissedSuggestions: [String],
        lastUsedTags: [String]
    ) {
        self.hasSeenContactsIntro = hasSeenContactsIntro
        self.hasSeenProfileIntro = hasSeenProfileIntro
        self.hasSeenNotificationsIntro = hasSeenNotificationsIntro
        self.hasSeenQuickpayIntro = hasSeenQuickpayIntro
        self.hasSeenShopIntro = hasSeenShopIntro
        self.hasSeenTransferIntro = hasSeenTransferIntro
        self.hasSeenTransferToSpendingIntro = hasSeenTransferToSpendingIntro
        self.hasSeenTransferToSavingsIntro = hasSeenTransferToSavingsIntro
        self.hasSeenWidgetsIntro = hasSeenWidgetsIntro
        self.hasDismissedWidgetsOnboardingHint = hasDismissedWidgetsOnboardingHint
        self.appUpdateIgnoreTimestamp = appUpdateIgnoreTimestamp
        self.backupIgnoreTimestamp = backupIgnoreTimestamp
        self.highBalanceIgnoreCount = highBalanceIgnoreCount
        self.highBalanceIgnoreTimestamp = highBalanceIgnoreTimestamp
        self.dismissedSuggestions = dismissedSuggestions
        self.lastUsedTags = lastUsedTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasSeenContactsIntro = try c.decode(Bool.self, forKey: .hasSeenContactsIntro)
        hasSeenProfileIntro = try c.decode(Bool.self, forKey: .hasSeenProfileIntro)
        hasSeenNotificationsIntro = try c.decode(Bool.self, forKey: .hasSeenNotificationsIntro)
        hasSeenQuickpayIntro = try c.decode(Bool.self, forKey: .hasSeenQuickpayIntro)
        hasSeenShopIntro = try c.decode(Bool.self, forKey: .hasSeenShopIntro)
        hasSeenTransferIntro = try c.decode(Bool.self, forKey: .hasSeenTransferIntro)
        hasSeenTransferToSpendingIntro = try c.decode(Bool.self, forKey: .hasSeenTransferToSpendingIntro)
        hasSeenTransferToSavingsIntro = try c.decode(Bool.self, forKey: .hasSeenTransferToSavingsIntro)
        hasSeenWidgetsIntro = try c.decode(Bool.self, forKey: .hasSeenWidgetsIntro)
        hasDismissedWidgetsOnboardingHint = try c.decodeIfPresent(Bool.self, forKey: .hasDismissedWidgetsOnboardingHint) ?? false
        appUpdateIgnoreTimestamp = try c.decode(TimeInterval.self, forKey: .appUpdateIgnoreTimestamp)
        backupIgnoreTimestamp = try c.decode(TimeInterval.self, forKey: .backupIgnoreTimestamp)
        highBalanceIgnoreCount = try c.decode(Int.self, forKey: .highBalanceIgnoreCount)
        highBalanceIgnoreTimestamp = try c.decode(TimeInterval.self, forKey: .highBalanceIgnoreTimestamp)
        dismissedSuggestions = try c.decode([String].self, forKey: .dismissedSuggestions)
        lastUsedTags = try c.decode([String].self, forKey: .lastUsedTags)
    }

    private enum CodingKeys: String, CodingKey {
        case hasSeenContactsIntro, hasSeenProfileIntro, hasSeenNotificationsIntro, hasSeenQuickpayIntro
        case hasSeenShopIntro, hasSeenTransferIntro, hasSeenTransferToSpendingIntro, hasSeenTransferToSavingsIntro
        case hasSeenWidgetsIntro, hasDismissedWidgetsOnboardingHint
        case appUpdateIgnoreTimestamp, backupIgnoreTimestamp, highBalanceIgnoreCount, highBalanceIgnoreTimestamp
        case dismissedSuggestions, lastUsedTags
    }
}

struct BlocktankBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let orders: [IBtOrder]
    let cjitEntries: [IcJitEntry]
    let info: IBtInfo?
}

struct ActivityBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let activities: [Activity]
    let activityTags: [ActivityTags]
    let closedChannels: [ClosedChannelDetails]
}

struct SettingsBackupV1 {
    let version: Int
    let createdAt: UInt64
    let settings: [String: Any]

    init(version: Int, createdAt: UInt64, settings: [String: Any]) {
        self.version = version
        self.createdAt = createdAt
        self.settings = settings
    }

    static func decode(from data: Data) throws -> SettingsBackupV1 {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = dict["version"] as? Int,
              let createdAt = dict["createdAt"] as? UInt64,
              let settings = dict["settings"] as? [String: Any]
        else {
            throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode SettingsBackupV1"])
        }
        return SettingsBackupV1(version: version, createdAt: createdAt, settings: settings)
    }

    func encode() throws -> Data {
        let dict: [String: Any] = [
            "version": version,
            "createdAt": createdAt,
            "settings": settings,
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

struct WidgetsBackupV1 {
    let version: Int
    let createdAt: UInt64
    let widgets: [String: Any]

    init(version: Int, createdAt: UInt64, widgets: [String: Any]) {
        self.version = version
        self.createdAt = createdAt
        self.widgets = widgets
    }

    static func decode(from data: Data) throws -> WidgetsBackupV1 {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = dict["version"] as? Int,
              let createdAt = dict["createdAt"] as? UInt64,
              let widgets = dict["widgets"] as? [String: Any]
        else {
            throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode WidgetsBackupV1"])
        }
        return WidgetsBackupV1(version: version, createdAt: createdAt, widgets: widgets)
    }

    func encode() throws -> Data {
        let dict: [String: Any] = [
            "version": version,
            "createdAt": createdAt,
            "widgets": widgets,
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }
}
