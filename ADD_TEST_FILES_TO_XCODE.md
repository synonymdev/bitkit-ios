# Add Test Files to Xcode Project

## Files to Add

The following test helper files need to be added to the BitkitUITests target:

1. `BitkitUITests/Helpers/PubkyRingTestHelper.swift`
2. `BitkitUITests/Helpers/WalletTestHelper.swift`

## Steps to Add Files

### Option 1: Via Xcode (Recommended)

1. Open `Bitkit.xcodeproj` in Xcode
2. In the Project Navigator, locate the `BitkitUITests` group
3. Expand the `Helpers` folder (create if doesn't exist)
4. Right-click on `Helpers` folder → "Add Files to Bitkit"
5. Navigate to `BitkitUITests/Helpers/`
6. Select both `PubkyRingTestHelper.swift` and `WalletTestHelper.swift`
7. **IMPORTANT**: In the dialog:
   - ✅ Check "Copy items if needed" (leave unchecked since files are already in place)
   - ✅ Check "Create groups"
   - ✅ Check target membership: **BitkitUITests** ONLY
   - ❌ Uncheck Bitkit target
   - ❌ Uncheck BitkitNotification target
8. Click "Add"

### Option 2: Verify Files are Added

After adding, verify:

1. Select each file in Project Navigator
2. Open File Inspector (right panel)
3. Verify "Target Membership" shows only BitkitUITests is checked

### Option 3: Test the Build

```bash
# Build UI Tests
xcodebuild -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
  build-for-testing

# Or build in Xcode: Cmd+Shift+U
```

## Files Already Exist

The files are already created and committed to git at:
- `BitkitUITests/Helpers/PubkyRingTestHelper.swift` ✅
- `BitkitUITests/Helpers/WalletTestHelper.swift` ✅
- `BitkitUITests/PaykitE2ETests.swift` ✅

## Why This Step is Needed

Xcode uses `project.pbxproj` file to track which files are part of which targets. Simply creating files in the directory structure doesn't automatically add them to the build system. This manual step is required to:

1. Include files in the BitkitUITests target compilation
2. Make XCTest framework imports work
3. Allow tests to run via Cmd+U or `xcodebuild test`

## After Adding Files

Once files are added to Xcode:

1. Build should succeed (Cmd+Shift+U)
2. Tests will appear in Test Navigator
3. Can run individual tests or entire test suite
4. Commit the updated `Bitkit.xcodeproj/project.pbxproj` file

