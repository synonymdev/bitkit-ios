# Fix PipUniFFI Module in Main Bitkit Project

**Location**: `/Users/johncarvalho/Library/Mobile Documents/com~apple~CloudDocs/vibes/bitkit-ios`

**Error**: `Unable to find module dependency: 'PipUniFFI'`

---

## Quick Fix Steps in Xcode

### Step 1: Add Framework to Project

1. **Open** `bitkit-ios/Bitkit.xcodeproj` in Xcode
2. **Right-click** on "Bitkit" (top item in project navigator)
3. **Select "Add Files to Bitkit..."**
4. **Navigate to**:
   ```
   /Users/johncarvalho/Library/Mobile Documents/com~apple~CloudDocs/vibes/pip/sdk/pip-uniffi/PipUniFFI.xcframework
   ```
5. **Important**:
   - ✅ **Uncheck** "Copy items if needed"
   - ✅ **Check** "Create groups"
   - ✅ **Check** "Add to targets: Bitkit"
6. **Click "Add"**

### Step 2: Link Framework in Target

1. **Select "Bitkit" target** (blue icon)
2. **Go to "General" tab**
3. **Scroll to "Frameworks, Libraries, and Embedded Content"**
4. **Click "+" button**
5. **If framework is already listed**, skip to Step 3
6. **If not listed**:
   - Click "Add Other..." → "Add Files..."
   - Select `PipUniFFI.xcframework`
   - Set "Embed" to **"Embed & Sign"**

### Step 3: Set Framework Search Paths

1. **Select "Bitkit" target**
2. **Go to "Build Settings" tab**
3. **Click "All"** (to show all settings)
4. **Search for "Framework Search Paths"**
5. **Double-click the value** (or expand the arrow)
6. **Click "+" to add new path**
7. **Enter**:
   ```
   $(SRCROOT)/../pip/sdk/pip-uniffi
   ```
   Or absolute path:
   ```
   /Users/johncarvalho/Library/Mobile Documents/com~apple~CloudDocs/vibes/pip/sdk/pip-uniffi
   ```
8. **Press Enter**

### Step 4: Set Import Paths (Swift)

1. **Still in "Build Settings"**
2. **Search for "Import Paths"** (Swift Compiler - Search Paths)
3. **Double-click the value**
4. **Click "+" to add**
5. **Enter**:
   ```
   $(SRCROOT)/Bitkit/PipSDK
   ```
6. **Press Enter**

### Step 5: Set Header Search Paths

1. **Search for "Header Search Paths"**
2. **Double-click the value**
3. **Click "+" to add**
4. **Enter**:
   ```
   $(SRCROOT)/Bitkit/PipSDK
   ```
5. **Press Enter**

### Step 6: Verify Module Map

1. **In Project Navigator**, check if `Bitkit/PipSDK/pipFFI.modulemap` exists
2. **If missing**, add it:
   - Right-click `PipSDK` folder
   - "Add Files to Bitkit..."
   - Navigate to the file
   - Ensure "Add to targets: Bitkit" is checked

### Step 7: Clean and Rebuild

```
Cmd+Shift+K  (Clean)
Cmd+B        (Build)
```

---

## Verify Framework Path

The framework should be at:
```
/Users/johncarvalho/Library/Mobile Documents/com~apple~CloudDocs/vibes/pip/sdk/pip-uniffi/PipUniFFI.xcframework
```

Relative to your project:
```
../pip/sdk/pip-uniffi/PipUniFFI.xcframework
```

---

## Alternative: Copy Framework to Project

If the relative path doesn't work:

1. **Copy framework** to project:
   ```bash
   cp -R /path/to/pip/sdk/pip-uniffi/PipUniFFI.xcframework \
         /Users/johncarvalho/Library/Mobile Documents/com~apple~CloudDocs/vibes/bitkit-ios/
   ```

2. **Add from project root**:
   - Use path: `$(SRCROOT)/PipUniFFI.xcframework`

---

## Troubleshooting

### Still Can't Find Module

1. **Check framework is actually linked**:
   - General tab → Frameworks, Libraries, and Embedded Content
   - Should see `PipUniFFI.xcframework` listed

2. **Try absolute path** in Framework Search Paths:
   ```
   /Users/johncarvalho/Library/Mobile Documents/com~apple~CloudDocs/vibes/pip/sdk/pip-uniffi
   ```

3. **Verify module map**:
   - File should exist: `Bitkit/PipSDK/pipFFI.modulemap`
   - Content should be:
   ```swift
   framework module PipUniFFI {
       umbrella header "pipFFI.h"
       export *
       module * { export * }
   }
   ```

4. **Check build destination**:
   - Should be iOS Simulator (not macOS)
   - Scheme selector: "iPhone 15 Pro" or similar

5. **Restart Xcode**:
   - Quit completely
   - Reopen project
   - Clean and rebuild

---

**Follow these steps in Xcode to fix the module import!** ✅

