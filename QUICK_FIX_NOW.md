# Quick Fix - Do This Now in Xcode

**Error**: `Unable to find module dependency: 'PipUniFFI'`

---

## ⚡ 3-Minute Fix

### Step 1: Fix Framework Search Path

1. **Select "Bitkit" target** in Xcode
2. **Go to "Build Settings" tab**
3. **Click "All"** (not "Basic")
4. **Search for "Framework Search Paths"**
5. **Find the entry** that says: `$(SRCROOT)/../../sdk/pip-uniffi`
6. **Double-click it** to edit
7. **Change to**: `$(SRCROOT)/../pip/sdk/pip-uniffi`
8. **Press Enter**

### Step 2: Add Import Paths (If Missing)

1. **Still in "Build Settings"**
2. **Search for "Import Paths"** (Swift Compiler - Search Paths)
3. **If empty or missing**, add: `$(SRCROOT)/Bitkit/PipSDK`

### Step 3: Clean and Rebuild

```
Cmd+Shift+K  (Clean)
Cmd+B        (Build)
```

---

## Why This Fixes It

The framework search path was pointing to the wrong location:
- ❌ **Wrong**: `$(SRCROOT)/../../sdk/pip-uniffi` (goes up 2 levels, then to sdk)
- ✅ **Correct**: `$(SRCROOT)/../pip/sdk/pip-uniffi` (goes up 1 level to vibes, then into pip)

From `bitkit-ios/`, the path to the framework is:
```
../pip/sdk/pip-uniffi/PipUniFFI.xcframework
```

---

## Verify It Worked

After rebuilding:
- ✅ No red error for `import PipUniFFI`
- ✅ Build succeeds
- ✅ Module is found

---

**This should fix it!** ✅

