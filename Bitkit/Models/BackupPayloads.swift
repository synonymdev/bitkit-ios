import BitkitCore
import Foundation

// MARK: - Backup Payload Models

struct WalletBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let transfers: [Transfer]
    let privatePaykitHighestReservedReceiveIndexByAddressType: [String: UInt32]?
    let paykitSdkBackupState: String?
    let watchOnlyAccounts: [WatchOnlyAccountRecord]?
    let watchOnlyAccountAllocationState: WatchOnlyAccountAllocationState?
}

struct MetadataBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let tagMetadata: [PreActivityMetadata]
    let cache: AppCacheData
    let pubkySession: PubkySessionBackupV1?
    let pubkyContactProfileOverrides: [String: PubkyProfileData]?
}

struct PubkySessionBackupV1: Codable, Equatable {
    enum Kind: String, Codable {
        case localSeed
        case externalSession
    }

    let kind: Kind
    let sessionSecret: String?
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
    let quickPaySpendDayKey: String
    let quickPaySpentCentsToday: Int64
    let quickPayReservations: [String: QuickPaySpendReservation]

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
        lastUsedTags: [String],
        quickPaySpendDayKey: String = "",
        quickPaySpentCentsToday: Int64 = 0,
        quickPayReservations: [String: QuickPaySpendReservation] = [:]
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
        self.quickPaySpendDayKey = quickPaySpendDayKey
        self.quickPaySpentCentsToday = quickPaySpentCentsToday
        self.quickPayReservations = quickPayReservations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasSeenContactsIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenContactsIntro) ?? false
        hasSeenProfileIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenProfileIntro) ?? false
        hasSeenNotificationsIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenNotificationsIntro) ?? false
        hasSeenQuickpayIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenQuickpayIntro) ?? false
        hasSeenShopIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenShopIntro) ?? false
        hasSeenTransferIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenTransferIntro) ?? false
        hasSeenTransferToSpendingIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenTransferToSpendingIntro) ?? false
        hasSeenTransferToSavingsIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenTransferToSavingsIntro) ?? false
        hasSeenWidgetsIntro = try c.decodeIfPresent(Bool.self, forKey: .hasSeenWidgetsIntro) ?? false
        hasDismissedWidgetsOnboardingHint = try c.decodeIfPresent(Bool.self, forKey: .hasDismissedWidgetsOnboardingHint) ?? false
        appUpdateIgnoreTimestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .appUpdateIgnoreTimestamp) ?? 0
        backupIgnoreTimestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .backupIgnoreTimestamp) ?? 0
        highBalanceIgnoreCount = try c.decodeIfPresent(Int.self, forKey: .highBalanceIgnoreCount) ?? 0
        highBalanceIgnoreTimestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .highBalanceIgnoreTimestamp) ?? 0
        dismissedSuggestions = try c.decodeIfPresent([String].self, forKey: .dismissedSuggestions) ?? []
        lastUsedTags = try c.decodeIfPresent([String].self, forKey: .lastUsedTags) ?? []
        quickPaySpendDayKey = try c.decodeIfPresent(String.self, forKey: .quickPaySpendDayKey) ?? ""
        quickPaySpentCentsToday = try c.decodeIfPresent(Int64.self, forKey: .quickPaySpentCentsToday) ?? 0
        quickPayReservations = try c.decodeIfPresent([String: QuickPaySpendReservation].self, forKey: .quickPayReservations) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case hasSeenContactsIntro, hasSeenProfileIntro, hasSeenNotificationsIntro, hasSeenQuickpayIntro
        case hasSeenShopIntro, hasSeenTransferIntro, hasSeenTransferToSpendingIntro, hasSeenTransferToSavingsIntro
        case hasSeenWidgetsIntro, hasDismissedWidgetsOnboardingHint
        case appUpdateIgnoreTimestamp, backupIgnoreTimestamp, highBalanceIgnoreCount, highBalanceIgnoreTimestamp
        case dismissedSuggestions, lastUsedTags
        case quickPaySpendDayKey, quickPaySpentCentsToday, quickPayReservations
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
