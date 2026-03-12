---
description: "Create a new release: bump version, create PR, tag, draft release, optionally upload to TestFlight"
allowed_tools: Bash, Read, Edit, Write, Glob, Grep, AskUserQuestion, mcp__github__create_pull_request, mcp__github__list_pull_requests, mcp__github__pull_request_read, mcp__github__get_file_contents, mcp__github__update_pull_request
---

Automate the full release process for bitkit-ios. See `Docs/RELEASE.md` for the complete manual process.

**Examples:**
- `/release` - Interactive, prompts for version (defaults to patch bump)

## Steps

### 1. Read Current Version

Read `Bitkit.xcodeproj/project.pbxproj` and extract the **first** occurrence of:
- `CURRENT_PROJECT_VERSION` that is NOT `= 1` (integer, e.g. `180`)
- `MARKETING_VERSION` that is NOT `= 1.0` (string, e.g. `2.0.6`)

Parse MARKETING_VERSION into `{major}.{minor}.{patch}` components.

Compute defaults:
- Next patch: `{major}.{minor}.{patch+1}`
- Next minor: `{major}.{minor+1}.0`
- Next major: `{major+1}.0.0`
- Next build number: `CURRENT_PROJECT_VERSION + 1`

### 2. Ask for Version

Use `AskUserQuestion` with header "Version":

**Question:** `"New version? (current: {MARKETING_VERSION}, build {CURRENT_PROJECT_VERSION})"`

**Options:**
1. `{major}.{minor}.{patch+1}` (Recommended) — description: "Patch release"
2. `{major}.{minor+1}.0` — description: "Minor release"
3. `{major+1}.0.0` — description: "Major release"

The user can always pick "Other" to enter a custom version string.

Store the chosen version as `newVersionName` and compute `newBuildNumber = CURRENT_PROJECT_VERSION + 1`.

### 2b. Ask for Base (patch releases only)

If the user chose a **patch** release, use `AskUserQuestion`:

**Question:** `"Branch from? Patch releases can be cut from master or from a previous tag with cherry-picked commits."`

**Options:**
1. "master" (Recommended) — description: "Branch from latest master"
2. "Previous tag" — description: "Branch from a tag (e.g. v{oldVersionName}), then cherry-pick commits"

If "Previous tag": ask `"Which tag?"` with a text input (default: `v{oldVersionName}`). Store as `{baseRef}`.

If "master" or if the release is minor/major: `{baseRef} = master`.

### 3. Create Release Branch & Bump Version

```bash
git fetch origin
git checkout {baseRef}
```

If `{baseRef}` is `master`, pull latest: `git pull origin master`. Skip pull if baseRef is a tag.

```bash
git checkout -b release-{newVersionName}
```

If the base is a tag (not master), print:
```
Release branch created from {baseRef}.
Cherry-pick the commits you need onto this branch now, then continue.
```
Wait for the user to confirm they are done cherry-picking before proceeding.

Edit `Bitkit.xcodeproj/project.pbxproj` using sed to replace **all** occurrences of the old values (test targets use `= 1` / `= 1.0` so they won't match):

```bash
sed -i '' "s/CURRENT_PROJECT_VERSION = {oldBuildNumber};/CURRENT_PROJECT_VERSION = {newBuildNumber};/g" Bitkit.xcodeproj/project.pbxproj
sed -i '' "s/MARKETING_VERSION = {oldVersionName};/MARKETING_VERSION = {newVersionName};/g" Bitkit.xcodeproj/project.pbxproj
```

Verify the edit updated exactly 4 occurrences of each (Bitkit Debug/Release + BitkitNotification Debug/Release).

```bash
git add Bitkit.xcodeproj/project.pbxproj
git commit -m "chore: version {newVersionName}"
git push -u origin release-{newVersionName}
```

### 4. Create Version Bump PR

Read `.github/pull_request_template.md` for structure. Create PR:

- **Title:** `chore: bump version {newVersionName}`
- **Base:** master
- **Body:**
```
Bump version to {newVersionName} (build {newBuildNumber}) for release.

### Description

- `CURRENT_PROJECT_VERSION`: {oldBuildNumber} → {newBuildNumber}
- `MARKETING_VERSION`: {oldVersionName} → {newVersionName}

### Screenshot / Video

N/A
```

Store the PR URL for the summary.

### 5. Tag & Draft GitHub Release

Create the tag and draft release early so auto-generated release notes are available during QA.

Determine the previous version tag for changelog generation: `v{oldVersionName}`.

```bash
git tag -a v{newVersionName} -m "v{newVersionName}"
git push origin v{newVersionName}
```

```bash
gh release create v{newVersionName} \
  --title "v{newVersionName}" \
  --draft \
  --generate-notes \
  --notes-start-tag v{oldVersionName} \
  --target release-{newVersionName}
```

### 6. Generate Store Release Notes

Fetch the auto-generated release notes from the draft release:

```bash
gh release view v{newVersionName} --json body --jq .body
```

Using those notes as context, write a concise user-facing summary of the release (2-3 sentences max, no commit hashes or PR numbers, written for end users not developers). Focus on new features and important bug fixes. Omit chores, maintenance, refactoring, CI changes, and test coverage improvements — these are not relevant to App Store users. Translate the summary into 5 languages.

Create `.ai/` directory if it doesn't exist. Save to `.ai/release-notes-{newVersionName}.md`:

```markdown
# Release Notes v{newVersionName}

## English
{summary}

## French
{french translation}

## Spanish
{spanish translation}

## Portuguese
{portuguese translation}

## German
{german translation}
```

Then prepend the English summary to the draft release body on GitHub:

```bash
# Read existing body and prepend store summary via temp file (avoids shell expansion issues)
EXISTING=$(gh release view v{newVersionName} --json body --jq .body)
printf '%s\n\n%s\n\n---\n\n%s\n' \
  '## Store Release Notes' \
  '{english summary}' \
  "$EXISTING" > /tmp/release-notes.md
gh release edit v{newVersionName} --notes-file /tmp/release-notes.md
```

Print the path to the release notes file so the user can share it for review.

### 7. Build & Upload to TestFlight (optional)

Use `AskUserQuestion`:

**Question:** `"Archive and upload to TestFlight?"`

**Options:**
1. "Skip — I'll build and upload manually via Xcode"
2. "CLI — Archive and upload via command line"

**If Skip (manual):**

Print these instructions:
```
Manual build steps:
1. Open Bitkit.xcodeproj in Xcode
2. Select "Any iOS Device (arm64)" from the target dropdown
3. Product → Archive (wait for build to complete)
4. In the Archives window, select the new archive → "Distribute App"
5. Choose "App Store Connect" distribution
6. After upload, go to https://appstoreconnect.apple.com/
7. Select Bitkit app → TestFlight
8. When the build is ready, set compliance:
   - "Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system"
   - Distribute in France: "Yes"
```

**If CLI:**

Ensure `ExportOptions.plist` exists in the repo root with `app-store-connect` method. If missing, create it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
```

Archive:
```bash
xcodebuild archive \
  -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -archivePath ./build/Bitkit.xcarchive \
  -configuration Release
```

Export and upload to TestFlight (requires App Store Connect API key in `~/.appstoreconnect/private_keys/` — see `Docs/RELEASE.md` for setup):
```bash
xcodebuild -exportArchive \
  -archivePath ./build/Bitkit.xcarchive \
  -exportPath ./build/export \
  -exportOptionsPlist ExportOptions.plist \
  -authenticationKeyID $APPSTORE_KEY_ID \
  -authenticationKeyIssuerID $APPSTORE_ISSUER_ID
```

If any step fails, stop and report the error to the user.

After upload, remind about compliance:
```
TestFlight compliance (set in App Store Connect after build processes):
- Encryption: "Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system"
- Distribute in France: "Yes"
```

### 8. Return to Master (CLI build only)

If the user chose the CLI build path (build is done), return to master:

```bash
git checkout master
```

If the user chose manual build, **stay on the release branch** — they need to be on it to build in Xcode. Do NOT checkout master.

### 9. Output Summary

```
Release v{newVersionName} (build {newBuildNumber})

Version bump PR: {PR URL}
Release branch: release-{newVersionName}
Tag: v{newVersionName}
Draft release: {release URL}

Store release notes: .ai/release-notes-{newVersionName}.md

Next steps:
- Share release notes with Jacobo for review
- Build and upload to TestFlight (if not done above)
- Set TestFlight compliance after build processes
- QA on TestFlight
- If patching the release branch: increment only the build number, re-tag, and re-upload (see Docs/RELEASE.md)
- Submit for App Store review when QA passes
- Publish the draft release on GitHub after App Store release
- Merge release branch PR into master
```
