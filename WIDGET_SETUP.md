# iOS Home Screen Widget Setup Guide

This guide will help you add the Bitcoin Facts widget as an iOS home screen widget using WidgetKit.

## Overview

All the necessary widget files have been created in the `BitkitWidget/` directory:
- `BitkitWidget.swift` - Main widget implementation
- `WidgetFactsService.swift` - Service for providing facts to the widget
- `Info.plist` - Widget extension configuration
- `BitkitWidget.entitlements` - App Groups entitlement
- `Assets.xcassets/` - Widget assets

## Setup Steps in Xcode

### 1. Add Widget Extension Target

1. Open `Bitkit.xcodeproj` in Xcode
2. Click on the project in the Project Navigator
3. At the bottom of the Targets list, click the **"+"** button
4. Select **"Widget Extension"** from the template chooser
5. Configure the new target:
   - **Product Name**: `BitkitWidget`
   - **Include Configuration Intent**: Leave **unchecked** (we don't need configuration)
   - Click **Finish**
6. When prompted "Activate BitkitWidget scheme?", click **Activate**

### 2. Replace Template Files

Xcode will have created template files. Replace/delete them:

1. **Delete** the auto-generated files in the `BitkitWidget` folder:
   - `BitkitWidget.swift` (template version)
   - `BitkitWidgetBundle.swift` (if separate)
   - `BitkitWidgetLiveActivity.swift` (if created)
   - `AppIntent.swift` (if created)

2. **Add** the files we created to the BitkitWidget target:
   - Right-click on the `BitkitWidget` folder in Xcode
   - Select **"Add Files to Bitkit..."**
   - Navigate to the `BitkitWidget` folder
   - Select:
     - `BitkitWidget.swift`
     - `WidgetFactsService.swift`
   - Make sure **"BitkitWidget"** target is checked
   - Click **Add**

### 3. Configure Target Settings

#### Bundle Identifier
1. Select the **BitkitWidget** target
2. Go to **General** tab
3. Set **Bundle Identifier** to: `to.bitkit.BitkitWidget` (or match your main app's bundle ID + `.BitkitWidget`)

#### Deployment Target
1. In the **General** tab
2. Set **Minimum Deployments** to match your main app (iOS 16.0 or higher recommended for widgets)

#### Entitlements
1. Select the **BitkitWidget** target
2. Go to **Signing & Capabilities** tab
3. Click **"+ Capability"**
4. Add **App Groups**
5. Check/add the app group: `group.bitkit`

### 4. Update Main App Entitlements (If Needed)

Make sure the main **Bitkit** target also has the App Groups capability:
1. Select the **Bitkit** target
2. Go to **Signing & Capabilities** tab
3. Verify **App Groups** capability exists with `group.bitkit`

### 5. Configure Info.plist

The `BitkitWidget/Info.plist` file should already be configured, but verify:
- `CFBundleDisplayName`: "Bitcoin Facts"
- `NSExtension` → `NSExtensionPointIdentifier`: "com.apple.widgetkit-extension"

### 6. Build and Run

1. Select the **BitkitWidget** scheme in Xcode
2. Choose a simulator or device
3. Build and run (Cmd+R)
4. Xcode will launch in widget preview mode
5. You should see the Bitcoin Facts widget in different sizes

### 7. Test on Device/Simulator

1. Switch back to the **Bitkit** scheme
2. Run the main app
3. On your home screen, long-press to enter edit mode
4. Tap the **"+"** button in the top-left corner
5. Search for **"Bitkit"** or **"Bitcoin Facts"**
6. Select the Bitcoin Facts widget
7. Choose a size (Small, Medium, or Large)
8. Tap **"Add Widget"**

## Widget Features

### Sizes Supported
- **Small**: Shows a single Bitcoin fact (4 lines max)
- **Medium**: Shows a Bitcoin fact (3 lines max)
- **Large**: Shows a Bitcoin fact (8 lines max)

### Update Frequency
- The widget automatically updates every 15 minutes with a new random fact
- Creates a 2-hour timeline with 8 entries

### Data Sharing
- The main app shares all Bitcoin facts with the widget via App Groups
- The widget falls back to built-in facts if App Groups aren't accessible

## Troubleshooting

### Widget Not Appearing
- Make sure both the main app and widget extension have App Groups enabled
- Verify the app group identifier is exactly `group.bitkit`
- Clean build folder (Cmd+Shift+K) and rebuild

### Facts Not Updating
- Ensure the main app has been launched at least once to populate shared data
- Check that App Groups entitlement is properly configured
- Try removing and re-adding the widget

### Build Errors
- Ensure the BitkitWidget target has the correct Deployment Target
- Verify all files are added to the BitkitWidget target (check Target Membership)
- Make sure WidgetKit framework is linked

## Customization

You can customize the widget appearance by editing `BitkitWidget.swift`:
- Colors: Modify the `LinearGradient` colors
- Fonts: Adjust the font sizes in `fontForFamily()`
- Layout: Customize the `VStack` spacing and padding
- Update interval: Change the timeline intervals in `getTimeline()`

## Next Steps

Consider adding more widget types:
- **Price Widget**: Show current Bitcoin price
- **Balance Widget**: Show wallet balance (with privacy considerations)
- **Activity Widget**: Show recent transactions
- **Block Height Widget**: Show current block height

Each would follow the same pattern as the Facts widget.

