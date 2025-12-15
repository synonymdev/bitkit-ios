# Xcode Framework Setup Instructions

## PaykitMobile and PubkyNoise XCFrameworks

The XCFrameworks are present but need to be linked in Xcode:

- `Bitkit/PaykitIntegration/Frameworks/PaykitMobile.xcframework`
- `Bitkit/PaykitIntegration/Frameworks/PubkyNoise.xcframework`

## Manual Steps Required

1. **Open Xcode Project**
   ```bash
   open Bitkit.xcodeproj
   ```

2. **Add Frameworks to Project**
   - Right-click on "Bitkit" in Project Navigator
   - Select "Add Files to Bitkit..."
   - Navigate to `Bitkit/PaykitIntegration/Frameworks/`
   - Select both `PaykitMobile.xcframework` and `PubkyNoise.xcframework`
   - **Important**: 
     - ✅ Check "Copy items if needed" (or leave unchecked if you want references)
     - ✅ Check "Create groups"
     - ✅ Check "Add to targets: Bitkit"

3. **Link Frameworks in Target**
   - Select "Bitkit" target (blue icon)
   - Go to "General" tab
   - Scroll to "Frameworks, Libraries, and Embedded Content"
   - Click "+" button
   - If frameworks are already listed, ensure they show "Embed & Sign"
   - If not listed:
     - Click "Add Other..." → "Add Files..."
     - Select the XCFrameworks
     - Set "Embed" to **"Embed & Sign"**

4. **Verify Framework Search Paths**
   - Select "Bitkit" target
   - Go to "Build Settings" tab
   - Search for "Framework Search Paths"
   - Ensure it includes: `$(PROJECT_DIR)/Bitkit/PaykitIntegration/Frameworks`
   - If missing, add it

5. **Clean and Rebuild**
   - Product → Clean Build Folder (⇧⌘K)
   - Product → Build (⌘B)

## Verification

After setup, the build should succeed and you should be able to:
- `import PaykitMobile` in Swift files
- `import PubkyNoise` in Swift files
- No "No such module" errors

## Note on PipUniFFI

The `PipUniFFI` module error is a pre-existing Bitkit issue, not related to Paykit integration. It needs to be resolved separately.

