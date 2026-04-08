# BitkitWidget - iOS Home Screen Widget

Bitcoin Facts widget for iOS home screen using WidgetKit.

## Quick Start

See the main **WIDGET_SETUP.md** file in the project root for detailed setup instructions.

## Files in this Directory

- **BitkitWidget.swift** - Main widget implementation with timeline provider and views
- **WidgetFactsService.swift** - Service for managing and providing Bitcoin facts
- **Info.plist** - Widget extension configuration
- **BitkitWidget.entitlements** - App Groups entitlement for data sharing
- **Assets.xcassets/** - Widget-specific assets

## Architecture

### Timeline Provider
The `FactsWidgetProvider` creates a timeline of widget entries that update every 15 minutes.

### Widget Entry
Each `FactsWidgetEntry` contains:
- A timestamp for when it should be displayed
- A Bitcoin fact string

### Widget View
The `BitkitWidgetEntryView` displays the fact with:
- A gradient background
- Bitcoin icon header
- Fact text (responsive to widget size)
- Source attribution footer

### Data Sharing
Facts are shared between the main app and widget via App Groups (`group.bitkit`), allowing the widget to display the same facts as the in-app widget.

## Widget Sizes

- **Small (2x2)**: Shows 4 lines of text
- **Medium (4x2)**: Shows 3 lines of text  
- **Large (4x4)**: Shows 8 lines of text

## Testing

1. Build and run the **BitkitWidget** scheme to preview in Xcode
2. Run the main **Bitkit** app, then add the widget to your home screen
3. The widget will update automatically every 15 minutes

## Future Enhancements

- Add interactive widget actions (iOS 17+)
- Support for Live Activities
- Additional widget families (extra large, lock screen widgets)
- Configuration options (font size, colors, update frequency)

