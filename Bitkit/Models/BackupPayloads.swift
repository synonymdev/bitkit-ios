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
    var hasSeenContactsIntro: Bool?
    var hasSeenProfileIntro: Bool?
    var hasSeenNotificationsIntro: Bool?
    var hasSeenQuickpayIntro: Bool?
    var hasSeenShopIntro: Bool?
    var hasSeenTransferIntro: Bool?
    var hasSeenTransferToSpendingIntro: Bool?
    var hasSeenTransferToSavingsIntro: Bool?
    var hasSeenWidgetsIntro: Bool?
    var hasDismissedWidgetsOnboardingHint: Bool?
    var appUpdateIgnoreTimestamp: TimeInterval?
    var backupIgnoreTimestamp: TimeInterval?
    var highBalanceIgnoreCount: Int?
    var highBalanceIgnoreTimestamp: TimeInterval?
    var dismissedSuggestions: [String]?
    var lastUsedTags: [String]?
    var quickPaySpendDayKey: String? = nil
    var quickPaySpentCentsToday: Int64? = nil
    var quickPayReservations: [String: QuickPaySpendReservation]? = nil
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
