# Date Internationalization in SwiftUI

This document outlines best practices for implementing internationalized date formatting in SwiftUI applications.

## Key Principles

### 1. Always Set Locale
```swift
let formatter = DateFormatter()
formatter.locale = Locale.current  // Essential for internationalization
formatter.dateStyle = .medium
formatter.timeStyle = .short
```

### 2. Use DateFormatter Styles Instead of Custom Formats (Usually)
```swift
// ✅ Good - Automatically adapts to locale
formatter.dateStyle = .medium
formatter.timeStyle = .short

// ❌ Avoid - Fixed format doesn't adapt to locale
formatter.dateFormat = "MMM d, yyyy h:mm a"

// ✅ Exception - When design requires specific format
// For consistent UI design, you may need specific formats like "May 26"
formatter.dateFormat = "MMM d"  // Still respects locale for month names
```

### 3. Consider Time Zones
```swift
formatter.timeZone = TimeZone.current  // or specific timezone
```

## DateFormatter Styles

### Date Styles
- `.none` - No date
- `.short` - 12/25/23 (US) or 25/12/23 (UK)
- `.medium` - Dec 25, 2023 (US) or 25 Dec 2023 (UK)
- `.long` - December 25, 2023
- `.full` - Monday, December 25, 2023

### Time Styles
- `.none` - No time
- `.short` - 3:30 PM
- `.medium` - 3:30:32 PM
- `.long` - 3:30:32 PM PST
- `.full` - 3:30:32 PM Pacific Standard Time

## Relative Date Formatting

For "time ago" style formatting, use `RelativeDateTimeFormatter`:

```swift
let relativeFormatter = RelativeDateTimeFormatter()
relativeFormatter.locale = Locale.current
relativeFormatter.dateTimeStyle = .named

// Returns localized strings like:
// English: "2 hours ago", "yesterday", "last week"
// Spanish: "hace 2 horas", "ayer", "la semana pasada"
// German: "vor 2 Stunden", "gestern", "letzte Woche"
```

## Calendar Considerations

Use `Calendar.current` for locale-aware calendar operations:

```swift
let calendar = Calendar.current
if calendar.isDateInToday(date) {
    // Show time only for today's dates
    formatter.timeStyle = .short
} else {
    // Show date and time for other dates
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
}
```

## Common Patterns in Bitkit

### Activity Row Formatting
```swift
// For activity lists - show time if today, date+time otherwise
private var formattedTime: String {
    let date = Date(timeIntervalSince1970: timestamp)
    let calendar = Calendar.current
    
    if calendar.isDateInToday(date) {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        return formatter.string(from: date)
    } else {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
```

### Activity Detail Formatting
```swift
// For detailed views - separate date and time
private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter
}()

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()
```

## Utility Helper

The `DateFormatterHelpers` utility provides common patterns:

```swift
// Activity time formatting
DateFormatterHelpers.formatActivityTime(timestamp)

// Activity detail formatting
let (date, time) = DateFormatterHelpers.formatActivityDetail(timestamp)

// Relative or absolute formatting
DateFormatterHelpers.formatRelativeOrAbsolute(timestamp)

// Specific "Month Day" format (e.g., "May 26")
DateFormatterHelpers.formatMonthDay(timestamp)

// Specific "Month Day, Time" format (e.g., "May 25, 21:07")
DateFormatterHelpers.formatDayMonthAtTime(timestamp)

// Localized activity group headers (e.g., "Today", "Yesterday", "December", etc.)
DateFormatterHelpers.getActivityGroupHeader(for: date)
```

## Bitkit-Specific Design Choices

### Month Day Format
For activity detail views, Bitkit uses a consistent "Month Day" format (e.g., "May 26") across all locales for better visual consistency in the UI. This format:

- Uses localized month names (Mai 26 in German, mayo 26 in Spanish)
- Maintains consistent layout regardless of locale
- Provides good readability without overwhelming detail

```swift
// Returns "May 26", "Mai 26", "mayo 26" etc. based on locale
DateFormatterHelpers.formatMonthDay(timestamp)
```

### Activity Row Format
For activity list rows, Bitkit uses a "Month Day, Time" format (e.g., "May 25, 21:07") for non-today dates, while showing just the time for today's activities. This format:

- Shows month first for natural reading
- Uses localized month names
- Uses 24-hour time format for consistency
- Clean comma separation between date and time

```swift
// Returns "May 25, 21:07", "Mai 25, 21:07", "mayo 25, 21:07" etc.
DateFormatterHelpers.formatDayMonthAtTime(timestamp)
```

### Activity Group Headers
For activity list grouping, Bitkit uses Apple's `DateFormatter` with relative formatting for "Today" and "Yesterday", and localized strings/formats for other periods. This provides:

- Automatic localization for "Today" and "Yesterday"
- Localized "This week" string for current week activities
- Localized "This month" string for current month activities
- Localized month/year combinations for older activities within the year
- Year-only format for very old activities

```swift
// Returns localized headers like:
// English: "Today", "Yesterday", "This week", "This month", "November 2023", "2022"
// German: "Heute", "Gestern", "Diese Woche", "Dieser Monat", "November 2023", "2022"
// French: "Aujourd'hui", "Hier", "Cette semaine", "Ce mois-ci", "novembre 2023", "2022"
DateFormatterHelpers.getActivityGroupHeader(for: activityDate)
```

## Testing Internationalization

### Simulator Testing
1. Go to Settings > General > Language & Region
2. Change region to test different date formats
3. Test with various locales: US, UK, Germany, Japan, etc.

### Code Testing
```swift
// Test with specific locales
let usFormatter = DateFormatter(dateStyle: .medium, timeStyle: .short, locale: Locale(identifier: "en_US"))
let germanFormatter = DateFormatter(dateStyle: .medium, timeStyle: .short, locale: Locale(identifier: "de_DE"))
let japaneseFormatter = DateFormatter(dateStyle: .medium, timeStyle: .short, locale: Locale(identifier: "ja_JP"))
```

## Common Mistakes to Avoid

### 1. Hardcoded Date Formats
```swift
// ❌ Don't do this
formatter.dateFormat = "MM/dd/yyyy"  // US-specific format

// ✅ Do this instead
formatter.dateStyle = .short  // Adapts to locale
```

### 2. Forgetting Locale
```swift
// ❌ Missing locale
let formatter = DateFormatter()
formatter.dateStyle = .medium

// ✅ With locale
let formatter = DateFormatter()
formatter.locale = Locale.current
formatter.dateStyle = .medium
```

### 3. Hardcoded Relative Time Strings
```swift
// ❌ English-only
return "\(hours) hours ago"

// ✅ Localized
let relativeFormatter = RelativeDateTimeFormatter()
relativeFormatter.locale = Locale.current
return relativeFormatter.localizedString(for: date, relativeTo: Date())
```

## Supported Locales in Bitkit

Based on the localization files, Bitkit supports:
- English (en)
- German (de)
- French (fr)
- Italian (it)
- Spanish (es-419)
- Polish (pl)
- Dutch (nl)
- Catalan (ca)
- Czech (cs)

Each locale will automatically format dates according to local conventions when proper internationalization is implemented.

## Resources

- [Apple's Date Formatting Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DataFormatting/Articles/dfDateFormatting10_4.html)
- [NSDateFormatter Class Reference](https://developer.apple.com/documentation/foundation/dateformatter)
- [RelativeDateTimeFormatter](https://developer.apple.com/documentation/foundation/relativedatetimeformatter)