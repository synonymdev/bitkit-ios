import Foundation

/// Ordered field set used by the v61 Blocks widget.
///
/// Shared between the main app and the WidgetKit extension via the App Group target membership.
/// Labels are intentionally hardcoded English to avoid reaching into the main app's
/// `LocalizeHelpers` from the widget extension.
enum BlocksWidgetField: String, CaseIterable {
    case height
    case time
    case date
    case transactionCount
    case size
    case fees

    var label: String {
        switch self {
        case .height: return "Block"
        case .time: return "Time"
        case .date: return "Date"
        case .transactionCount: return "Transactions"
        case .size: return "Size"
        case .fees: return "Fees"
        }
    }

    /// Asset name for the brand-orange icon used in both the wide and compact layouts.
    var iconName: String {
        switch self {
        case .height: return "cube"
        case .time: return "clock"
        case .date: return "calendar"
        case .transactionCount: return "arrow-up-down"
        case .size: return "file-text"
        case .fees: return "coins"
        }
    }

    func isEnabled(in options: BlocksWidgetOptions) -> Bool {
        switch self {
        case .height: return options.height
        case .time: return options.time
        case .date: return options.date
        case .transactionCount: return options.transactionCount
        case .size: return options.size
        case .fees: return options.fees
        }
    }

    func value(from data: CachedBlock) -> String {
        switch self {
        case .height: return data.height
        case .time: return data.time
        case .date: return data.date
        case .transactionCount: return data.transactionCount
        case .size: return data.size
        case .fees: return data.fees
        }
    }
}

extension BlocksWidgetOptions {
    /// All enabled fields in declared order.
    var enabledFields: [BlocksWidgetField] {
        BlocksWidgetField.allCases.filter { $0.isEnabled(in: self) }
    }
}
