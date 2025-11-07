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
    let tagMetadata: [ActivityTagsMetadata]
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
    let showHomeViewEmptyState: Bool
    let appUpdateIgnoreTimestamp: TimeInterval
    let backupIgnoreTimestamp: TimeInterval
    let highBalanceIgnoreCount: Int
    let highBalanceIgnoreTimestamp: TimeInterval
    let dismissedSuggestions: [String]
    let lastUsedTags: [String]
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
    let closedChannels: [ClosedChannelDetails]
}
