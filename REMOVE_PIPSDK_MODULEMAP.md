# Remove PipSDK Module Map from Xcode Project

**Problem**: Two module maps are conflicting:
1. `Bitkit/PipSDK/pipFFI.modulemap` (in project)
2. `PipUniFFI.xcframework/ios-arm64-simulator/Modules/module.modulemap` (in XCFramework)

Xcode is getting confused about which one to use.

---

## Solution: Remove PipSDK Module Map

The XCFramework **already has its own module map** that should be used automatically. The one in `PipSDK/` is causing a conflict.

---

## Steps in Xcode

### 1. Remove Module Map from Project

1. **In Xcode**, find `Bitkit/PipSDK/pipFFI.modulemap` in the project navigator
2. **Right-click** on the file
3. **Select "Delete"**
4. **Choose "Remove Reference"** (NOT "Move to Trash")
   - This removes it from the project but keeps the file on disk
   - We might need it later, so don't delete it completely

### 2. Verify Framework is Linked

1. **Select "Bitkit" target**
2. **Go to "General" tab**
3. **Check "Frameworks, Libraries, and Embedded Content"**
4. **Verify** `PipUniFFI.xcframework` is listed

### 3. Clean and Rebuild

```
Cmd+Shift+Option+K  (Clean Build Folder)
Cmd+B                (Build)
```

---

## Why This Works

- XCFrameworks automatically provide their own module maps
- The module map is in: `PipUniFFI.xcframework/ios-arm64-simulator/Modules/module.modulemap`
- Xcode should find it automatically when the framework is linked
- Having a duplicate module map in the project causes conflicts

---

## Alternative: If Removing Doesn't Work

If removing the PipSDK module map doesn't work, we can try:

1. **Keep the module map** but update it to point to the XCFramework header
2. **Or** add explicit `MODULEMAP_FILE` build setting pointing to the XCFramework module map

But the first approach (removing it) should work since XCFrameworks handle module maps automatically.

---

**Remove the PipSDK module map from the Xcode project, then clean and rebuild!** ✅

