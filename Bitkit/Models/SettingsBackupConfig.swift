import Foundation

/// Configuration for settings backup/restore operations
enum SettingsBackupConfig {
    enum SettingKeyType {
        case string(optional: Bool)
        case bool
        case double(optional: Bool, minValue: Double = 0)
        case int(optional: Bool, minValue: Int = 0)
        case stringArray(optional: Bool)
    }

    static let serverSettingsKeys: [String] = [
        "electrumServer",
        "rapidGossipSyncUrl",
    ]

    static let appStateKeys: [String] = [
        "hasSeenContactsIntro",
        "hasSeenProfileIntro",
        "hasSeenNotificationsIntro",
        "hasSeenQuickpayIntro",
        "hasSeenShopIntro",
        "hasSeenTransferIntro",
        "hasSeenTransferToSpendingIntro",
        "hasSeenTransferToSavingsIntro",
        "hasSeenWidgetsIntro",
        "showHomeViewEmptyState",
        "appUpdateIgnoreTimestamp",
        "backupIgnoreTimestamp",
        "highBalanceIgnoreCount",
        "highBalanceIgnoreTimestamp",
        "dismissedSuggestions",
        "lastUsedTags",
    ]

    static let settingsKeyTypes: [String: SettingKeyType] = [
        "primaryDisplay": .string(optional: true),
        "bitcoinDisplayUnit": .string(optional: true),
        "selectedCurrency": .string(optional: true),
        "defaultTransactionSpeed": .string(optional: true),
        "coinSelectionMethod": .string(optional: true),
        "coinSelectionAlgorithm": .string(optional: true),
        "enableQuickpay": .bool,
        "showWidgets": .bool,
        "showWidgetTitles": .bool,
        "swipeBalanceToHide": .bool,
        "hideBalance": .bool,
        "hideBalanceOnOpen": .bool,
        "readClipboard": .bool,
        "warnWhenSendingOver100": .bool,
        "backupVerified": .bool,
        "enableNotifications": .bool,
        "quickpayAmount": .double(optional: false),
    ]

    static var settingsKeys: [String] {
        Array(settingsKeyTypes.keys) + serverSettingsKeys
    }

    static let iosToAndroidFieldMapping: [String: String] = [
        "readClipboard": "enableAutoReadClipboard",
        "swipeBalanceToHide": "enableSwipeToHideBalance",
        "warnWhenSendingOver100": "enableSendAmountWarning",
        "bitcoinDisplayUnit": "displayUnit",
        "enableQuickpay": "isQuickPayEnabled",
        "enableNotifications": "notificationsGranted",
        // Note: PIN settings are intentionally NOT backed up for security
        // PIN itself cannot be backed up, so PIN settings shouldn't be either
    ]

    static let algorithmMapping: [String: String] = [
        "branchAndBound": "BranchAndBound",
        "largestFirst": "LargestFirst",
        "oldestFirst": "FirstInFirstOut",
        "singleRandomDraw": "SingleRandomDraw",
    ]

    static func convertAlgorithm(_ value: String, toAndroid: Bool) -> String {
        if toAndroid {
            return algorithmMapping[value] ?? "BranchAndBound"
        } else {
            // Reverse lookup
            for (ios, android) in algorithmMapping where android == value {
                return ios
            }
            return "largestFirst"
        }
    }
}
