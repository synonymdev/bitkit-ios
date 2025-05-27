import Foundation

/// Utility class for creating properly internationalized date formatters
struct DateFormatterHelpers {

    /// Creates a date formatter with proper locale settings
    /// - Parameters:
    ///   - dateStyle: The date style to use
    ///   - timeStyle: The time style to use
    ///   - locale: The locale to use (defaults to current)
    ///   - timeZone: The time zone to use (defaults to current)
    /// - Returns: Configured DateFormatter
    static func formatter(
        dateStyle: DateFormatter.Style = .none,
        timeStyle: DateFormatter.Style = .none,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    /// Creates a relative date formatter for "time ago" style formatting
    /// - Parameter locale: The locale to use (defaults to current)
    /// - Returns: Configured RelativeDateTimeFormatter
    static func relativeFormatter(locale: Locale = .current) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        return formatter
    }

    /// Formats a timestamp for activity display
    /// - Parameter timestamp: Unix timestamp
    /// - Returns: Localized date string
    static func formatActivityTime(_ timestamp: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            // For today, show time only
            return formatter(timeStyle: .short).string(from: date)
        } else {
            // For other days, show "May 25, 21:07" format
            return formatDayMonthAtTime(timestamp)
        }
    }

    /// Formats a date for activity detail view
    /// - Parameter timestamp: Unix timestamp
    /// - Returns: Tuple of (date string, time string)
    static func formatActivityDetail(_ timestamp: UInt64) -> (date: String, time: String) {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))

        // Use specific "Month Day" format
        let dateString = formatMonthDay(timestamp)

        // Keep time localized
        let timeString = formatter(timeStyle: .short).string(from: date)
        return (dateString, timeString)
    }

    /// Formats a date using relative formatting when appropriate
    /// - Parameter timestamp: Unix timestamp
    /// - Returns: Localized relative or absolute date string
    static func formatRelativeOrAbsolute(_ timestamp: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let now = Date()
        let timeInterval = now.timeIntervalSince(date)

        // Use relative formatting for dates within the last week
        if timeInterval < 7 * 24 * 60 * 60 {
            return relativeFormatter().localizedString(for: date, relativeTo: now)
        } else {
            return formatter(dateStyle: .medium).string(from: date)
        }
    }

    /// Formats a date in "Month Day" format (e.g., "May 26")
    /// - Parameter timestamp: Unix timestamp
    /// - Returns: Date string in "MMM d" format
    static func formatMonthDay(_ timestamp: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.dateFormat = "MMM d"
        return dateFormatter.string(from: date)
    }

    /// Formats a date in "Month Day, Time" format (e.g., "May 25, 21:07")
    /// - Parameter timestamp: Unix timestamp
    /// - Returns: Date string in "MMM d, HH:mm" format
    static func formatDayMonthAtTime(_ timestamp: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.dateFormat = "MMM d, HH:mm"
        return dateFormatter.string(from: date)
    }

    /// Gets a localized relative date group header for activity grouping
    /// - Parameter date: The date to get the group header for
    /// - Returns: Localized group header string (e.g., "Today", "Yesterday", "This Month", etc.)
    static func getActivityGroupHeader(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        
        // Check if it's today
        if calendar.isDateInToday(date) {
            // Use DateFormatter with relative formatting to get "Today"
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        
        // Check if it's yesterday
        if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
        
        // For this week, this month, this year, and earlier - use custom logic
        let beginningOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let beginningOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let beginningOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now
        
        if date >= beginningOfWeek {
            // This week - return localized "This week"
            return localizedString("wallet__activity_group_week", comment: "Activity group header for current week")
        } else if date >= beginningOfMonth {
            // This month - return localized "This month"
            return localizedString("wallet__activity_group_month", comment: "Activity group header for current month")
        } else if date >= beginningOfYear {
            // This year - use month and year
            let monthYearFormatter = DateFormatter()
            monthYearFormatter.locale = Locale.current
            monthYearFormatter.dateFormat = "MMMM yyyy"
            return monthYearFormatter.string(from: date)
        } else {
            // Earlier - use year only
            let yearFormatter = DateFormatter()
            yearFormatter.locale = Locale.current
            yearFormatter.dateFormat = "yyyy"
            return yearFormatter.string(from: date)
        }
    }
}

/// Extension to provide common date formatting patterns
extension DateFormatter {

    /// Convenience initializer for internationalized date formatter
    /// - Parameters:
    ///   - dateStyle: Date style
    ///   - timeStyle: Time style
    ///   - locale: Locale (defaults to current)
    convenience init(dateStyle: Style, timeStyle: Style, locale: Locale = .current) {
        self.init()
        self.locale = locale
        self.dateStyle = dateStyle
        self.timeStyle = timeStyle
    }
}
