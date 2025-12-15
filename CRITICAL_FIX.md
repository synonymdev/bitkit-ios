# Critical Fix - Module Map Location Issue

**Problem**: Files exist but Xcode can't find them because they're in the wrong project group.

---

## The Issue

The files `pipFFI.modulemap` and `pipFFI.h` are:
- ✅ **On disk**: `Bitkit/PipSDK/pipFFI.modulemap`
- ❌ **In project**: Referenced in a "swift" group (wrong location)

Xcode is looking for them in the wrong place!

---

## Quick Fix in Xcode

### Option 1: Update File References (Recommended)

1. **In Xcode**, find the files in project navigator:
   - Look for `pipFFI.modulemap` and `pipFFI.h`
   - They might be under a "swift" or "bindings" folder

2. **Select both files** (Cmd+Click to select multiple)

3. **In File Inspector** (right sidebar):
   - Find "Location" section
   - Click the folder icon next to the path
   - Navigate to: `Bitkit/PipSDK/`
   - Select the correct files
   - Click "Choose"

4. **Verify**:
   - Files should now show correct path
   - Should be in `Bitkit/PipSDK/` group

### Option 2: Remove and Re-add Files

1. **In Xcode**, find `pipFFI.modulemap` and `pipFFI.h` in project navigator
2. **Right-click** → "Delete"
3. **Choose "Remove Reference"** (don't move to trash)
4. **Right-click "Bitkit" folder** → "Add Files to Bitkit..."
5. **Navigate to** `Bitkit/PipSDK/`
6. **Select** `pipFFI.h` and `pipFFI.modulemap`
7. **Important**:
   - ✅ Check "Add to targets: Bitkit"
   - ✅ Uncheck "Copy items if needed"
   - ✅ Select "Create groups"
8. **Click "Add"**

### Option 3: Add Module Map to Headers Build Phase

The module map might need to be explicitly added:

1. **Select "Bitkit" target**
2. **Go to "Build Phases" tab**
3. **Expand "Headers"** (if it exists)
4. **If "Headers" doesn't exist**, you might need to add it:
   - Click "+" → "New Headers Phase"
5. **Click "+" in Headers section**
6. **Add** `pipFFI.modulemap`
7. **Set to "Public"** (drag to Public section)

---

## Verify Framework Search Path

Also double-check:

1. **"Build Settings" → "All"**
2. **Search "Framework Search Paths"**
3. **Should be**: `$(SRCROOT)/../pip/sdk/pip-uniffi`

---

## After Fixing

1. **Clean**: `Cmd+Shift+K`
2. **Rebuild**: `Cmd+B`
3. **Error should be gone** ✅

---

**The files are in the wrong project group. Fix the file references in Xcode!**

