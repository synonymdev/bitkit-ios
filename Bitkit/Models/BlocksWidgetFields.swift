import Foundation

/// Ordered field set used by the v61 Blocks widget. Default-selected fields come first so
/// the compact (`.systemSmall`) layout can prioritize them when the row cap kicks in.
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
    case showSource

    /// The four fields enabled by default. The compact layout always renders these first when
    /// present, then fills any remaining capacity with non-default fields.
    static let defaults: [BlocksWidgetField] = [.height, .time, .date, .transactionCount]
    static let extras: [BlocksWidgetField] = [.size, .fees, .showSource]

    var label: String {
        switch self {
        case .height: return "Block"
        case .time: return "Time"
        case .date: return "Date"
        case .transactionCount: return "Transactions"
        case .size: return "Size"
        case .fees: return "Fees"
        case .showSource: return "Source"
        }
    }

    /// Asset name for the brand-orange icon used in both the wide and compact layouts.
    var iconName: String {
        switch self {
        case .height: return "cube"
        case .time: return "clock"
        case .date: return "calendar"
        case .transactionCount: return "transfer"
        case .size: return "file-text"
        case .fees: return "coins"
        case .showSource: return "globe"
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
        case .showSource: return options.showSource
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
        case .showSource: return "mempool.space"
        }
    }
}

extension BlocksWidgetOptions {
    /// All enabled fields in declared order. Used by the wide / large layouts.
    var enabledFields: [BlocksWidgetField] {
        BlocksWidgetField.allCases.filter { $0.isEnabled(in: self) }
    }

    /// Compact layout caps at 4 fields. Defaults come first, extras fill any remaining slots.
    var compactFields: [BlocksWidgetField] {
        let defaults = BlocksWidgetField.defaults.filter { $0.isEnabled(in: self) }
        let extras = BlocksWidgetField.extras.filter { $0.isEnabled(in: self) }
        return Array((defaults + extras).prefix(4))
    }
}
