# Final Fix Steps - PipUniFFI Module

**Status**: ✅ Module map and header copied | ⏳ Need to verify/update framework search path

---

## ✅ What I Just Fixed

1. **Copied module map**: `Bitkit/PipSDK/pipFFI.modulemap` ✅
2. **Copied header**: `Bitkit/PipSDK/pipFFI.h` ✅
3. **Module map content**: Correctly defines `PipUniFFI` module ✅

---

## ⚡ Do This Now in Xcode

### Step 1: Add Files to Project (If Not Already Added)

1. **In Xcode**, check if `Bitkit/PipSDK/` folder is visible in project navigator
2. **If NOT visible**:
   - Right-click "Bitkit" folder
   - "Add Files to Bitkit..."
   - Navigate to `Bitkit/PipSDK/`
   - Select `pipFFI.h` and `pipFFI.modulemap`
   - ✅ Check "Add to targets: Bitkit"
   - Click "Add"

### Step 2: Verify Framework Search Path

1. **Select "Bitkit" target**
2. **Go to "Build Settings" tab**
3. **Click "All"** (not "Basic")
4. **Search for "Framework Search Paths"**
5. **Check the value** - it should be:
   ```
   $(SRCROOT)/../pip/sdk/pip-uniffi
   ```
6. **If it's different** (like `../../sdk/pip-uniffi`), **change it**:
   - Double-click the value
   - Change to: `$(SRCROOT)/../pip/sdk/pip-uniffi`
   - Press Enter

### Step 3: Verify Import Paths

1. **Still in "Build Settings"**
2. **Search for "Import Paths"** (Swift Compiler - Search Paths)
3. **Should include**: `$(SRCROOT)/Bitkit/PipSDK`
4. **If missing**, add it:
   - Double-click the value
   - Click "+"
   - Enter: `$(SRCROOT)/Bitkit/PipSDK`
   - Press Enter

### Step 4: Verify Header Search Paths

1. **Search for "Header Search Paths"**
2. **Should include**: `$(SRCROOT)/Bitkit/PipSDK`
3. **If missing**, add it (same way as above)

### Step 5: Verify Framework is Linked

1. **Go to "General" tab**
2. **Check "Frameworks, Libraries, and Embedded Content"**
3. **Verify** `PipUniFFI.xcframework` is listed
4. **If missing**, add it:
   - Click "+"
   - "Add Other..." → "Add Files..."
   - Navigate to: `../pip/sdk/pip-uniffi/PipUniFFI.xcframework`
   - Set "Embed" to "Embed & Sign"

### Step 6: Clean and Rebuild

```
Cmd+Shift+K  (Clean)
Cmd+B        (Build)
```

---

## Path Reference

From `bitkit-ios/` project:
- **Framework**: `../pip/sdk/pip-uniffi/PipUniFFI.xcframework`
- **Module map**: `Bitkit/PipSDK/pipFFI.modulemap` (now exists ✅)
- **Header**: `Bitkit/PipSDK/pipFFI.h` (now exists ✅)

---

## Expected Result

After these steps:
- ✅ `import PipUniFFI` should work
- ✅ Build succeeds
- ✅ No module errors

---

**Files are ready. Just verify the paths in Xcode!** ✅

