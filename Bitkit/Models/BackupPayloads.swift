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
    var usdtWallet: String? = nil
    var paykitPaymentState: PaykitPaymentStateBackup? = nil
    var publicPaykitLegacyAddresses: [String]? = nil
}

struct MetadataBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let tagMetadata: [PreActivityMetadata]
    let cache: AppCacheData
    let pubkySession: PubkySessionBackupV1?
    let pubkyContactProfileOverrides: [String: PubkyProfileData]?
    /// User-set hardware wallet names, keyed by bitkit-core wallet id. Nil in envelopes written
    /// before this field, and in envelopes from an app that knows no names. Shared with
    /// bitkit-android, which spells the key the same way — see its `MetadataBackupV1`.
    let hwWalletNames: [String: String]?
    /// The earlier Spark exit addresses each wallet watches, keyed `<network>/wallet<n>` as bitkit-android keys them.
    /// Nil in envelopes written before this field.
    var sparkExitEarlierAddresses: [String: [SparkExitEarlierAddressBackupV1]]?

    init(
        version: Int,
        createdAt: UInt64,
        tagMetadata: [PreActivityMetadata],
        cache: AppCacheData,
        pubkySession: PubkySessionBackupV1?,
        pubkyContactProfileOverrides: [String: PubkyProfileData]?,
        hwWalletNames: [String: String]? = nil,
        sparkExitEarlierAddresses: [String: [SparkExitEarlierAddressBackupV1]]? = nil
    ) {
        self.version = version
        self.createdAt = createdAt
        self.tagMetadata = tagMetadata
        self.cache = cache
        self.pubkySession = pubkySession
        self.pubkyContactProfileOverrides = pubkyContactProfileOverrides
        self.hwWalletNames = hwWalletNames
        self.sparkExitEarlierAddresses = sparkExitEarlierAddresses
    }
}

extension MetadataBackupV1 {
    /// An earlier exit address list this app can't read is left out, so it never fails the rest of the envelope.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decode(UInt64.self, forKey: .createdAt)
        tagMetadata = try c.decode([PreActivityMetadata].self, forKey: .tagMetadata)
        cache = try c.decode(AppCacheData.self, forKey: .cache)
        pubkySession = try c.decodeIfPresent(PubkySessionBackupV1.self, forKey: .pubkySession)
        pubkyContactProfileOverrides = try c.decodeIfPresent([String: PubkyProfileData].self, forKey: .pubkyContactProfileOverrides)
        hwWalletNames = try c.decodeIfPresent([String: String].self, forKey: .hwWalletNames)
        sparkExitEarlierAddresses = try? c.decodeIfPresent(
            [String: [SparkExitEarlierAddressBackupV1]].self,
            forKey: .sparkExitEarlierAddresses
        )
    }
}

/// An earlier Spark exit address as both apps back it up. `kind` is `keptChange` or `cancelledFunding`; a reader skips
/// one it does not know. What the address holds is read again from the chain.
struct SparkExitEarlierAddressBackupV1: Codable, Equatable {
    let address: String
    let path: String
    let kind: String
    let atMillis: Int64
}

struct PubkySessionBackupV1: Codable, Equatable {
    enum Kind: String, Codable {
        case localSeed
    }

    let kind: Kind?
}

extension PubkySessionBackupV1 {
    /// Backups written by older versions carry kinds this app no longer restores; they decode to no identity.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? container.decodeIfPresent(Kind.self, forKey: .kind)
    }
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
    let quickPayLedger: QuickPayLedger?
    let detachedActivityContacts: Set<String>
    /// Imported cache addresses may have been public; local snapshots do not export the live receive address.
    let onchainAddress: String?
    /// The funding key index each wallet's next Spark exit takes, keyed `<network>/wallet<n>` as bitkit-android keys
    /// its own. Nil in envelopes written before this field.
    let sparkExitNextFundingIndexes: [String: Int]?

    init(
        hasSeenContactsIntro: Bool,
        hasSeenProfileIntro: Bool,
        hasSeenNotificationsIntro: Bool,
        hasSeenQuickpayIntro: Bool,
        hasSeenShopIntro: Bool,
        hasSeenTransferIntro: Bool = false,
        hasSeenTransferToSpendingIntro: Bool = false,
        hasSeenTransferToSavingsIntro: Bool,
        hasSeenWidgetsIntro: Bool,
        hasDismissedWidgetsOnboardingHint: Bool,
        appUpdateIgnoreTimestamp: TimeInterval,
        backupIgnoreTimestamp: TimeInterval,
        highBalanceIgnoreCount: Int,
        highBalanceIgnoreTimestamp: TimeInterval,
        dismissedSuggestions: [String],
        lastUsedTags: [String],
        quickPayLedger: QuickPayLedger? = nil,
        detachedActivityContacts: Set<String> = [],
        sparkExitNextFundingIndexes: [String: Int]? = nil
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
        self.quickPayLedger = quickPayLedger
        self.detachedActivityContacts = detachedActivityContacts
        self.sparkExitNextFundingIndexes = sparkExitNextFundingIndexes
        onchainAddress = nil
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
        quickPayLedger = try c.decodeIfPresent(QuickPayLedger.self, forKey: .quickPayLedger)
        detachedActivityContacts = try c.decodeIfPresent(Set<String>.self, forKey: .detachedActivityContacts) ?? []
        onchainAddress = try c.decodeIfPresent(String.self, forKey: .onchainAddress)
        sparkExitNextFundingIndexes = try c.decodeIfPresent([String: Int].self, forKey: .sparkExitNextFundingIndexes)
    }

    private enum CodingKeys: String, CodingKey {
        case hasSeenContactsIntro, hasSeenProfileIntro, hasSeenNotificationsIntro, hasSeenQuickpayIntro
        case hasSeenShopIntro, hasSeenTransferIntro, hasSeenTransferToSpendingIntro, hasSeenTransferToSavingsIntro
        case hasSeenWidgetsIntro, hasDismissedWidgetsOnboardingHint
        case appUpdateIgnoreTimestamp, backupIgnoreTimestamp, highBalanceIgnoreCount, highBalanceIgnoreTimestamp
        case dismissedSuggestions, lastUsedTags
        case quickPayLedger
        case detachedActivityContacts
        case onchainAddress
        case sparkExitNextFundingIndexes
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

/// The Spark wallet's unilateral exit data, as `exportUnilateralExitState` returns it, kept so a wallet restored on
/// another device can still exit on-chain while the Spark operators are unreachable.
struct SparkExitBackupV1: Codable {
    let version: Int
    let createdAt: UInt64
    let network: String
    let exitState: String
}
