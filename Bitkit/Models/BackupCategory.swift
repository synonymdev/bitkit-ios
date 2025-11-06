import Foundation

enum BackupCategory: String, CaseIterable {
    case lightningConnections = "LIGHTNING_CONNECTIONS"
    case blocktank = "BLOCKTANK"
    case activity = "ACTIVITY"
    case wallet = "WALLET"
    case settings = "SETTINGS"
    case widgets = "WIDGETS"
    case metadata = "METADATA"
}

// MARK: - UI Extensions

extension BackupCategory {
    var uiIcon: String {
        switch self {
        case .lightningConnections:
            return "bolt-hollow"
        case .blocktank:
            return "note"
        case .activity:
            return "transfer"
        case .wallet:
            return "timer-alt"
        case .settings:
            return "gear-six"
        case .widgets:
            return "stack"
        case .metadata:
            return "tag"
        }
    }

    var uiTitle: String {
        switch self {
        case .lightningConnections:
            return t("settings__backup__category_connections")
        case .blocktank:
            return t("settings__backup__category_connection_receipts")
        case .activity:
            return t("settings__backup__category_transaction_log")
        case .wallet:
            return t("settings__backup__category_wallet")
        case .settings:
            return t("settings__backup__category_settings")
        case .widgets:
            return t("settings__backup__category_widgets")
        case .metadata:
            return t("settings__backup__category_tags")
        }
    }
}
