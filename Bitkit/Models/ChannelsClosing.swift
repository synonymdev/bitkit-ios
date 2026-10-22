import Foundation

enum ChannelsClosing {
    /// Date on which Blocktank closes the remaining Lightning channels; set before release.
    static let CHANNELS_CLOSE_DATE = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 12, day: 15)

    static func formattedCloseDate(locale: Locale = Locale(identifier: LocalizationHelper.currentLanguageCode)) -> String {
        guard let date = CHANNELS_CLOSE_DATE.date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
