# Bitkit iOS Release Process

## Overview

The release process has two paths:
- **Automated**: Run `/release` command (Claude Code or Cursor) to handle version bump, branch, PR, tag, and draft release.
- **Manual**: Follow the steps below.

Both paths end with a manual Xcode archive + TestFlight upload (or an optional CLI equivalent).

---

## 1. Create the Release Branch

For **minor** and **major** releases, branch off `master`:

```bash
git checkout master
git pull origin master
git checkout -b release-2.0.7
```

For **patch** releases, you may branch from `master` or from the previous release tag if only specific fixes are needed:

```bash
# From a previous tag (e.g. hotfix on top of v2.0.6)
git fetch origin
git checkout v2.0.6
git checkout -b release-2.0.7

# Cherry-pick the specific fixes needed
git cherry-pick <commit-hash-1> <commit-hash-2> ...
```

When branching from a tag, only the cherry-picked commits will be included. The PR to `master` will still be created so version bumps and patches are merged back after release.

### Bump Version

Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Bitkit.xcodeproj/project.pbxproj`.

Build numbers are kept in sync between Android and iOS. They may be incremented multiple times per release if issues are patched during testing.

Using sed (only updates the app and notification extension targets; test targets use different values and are unaffected):

```bash
# Replace old build number (e.g. 180) with new (e.g. 181)
sed -i '' 's/CURRENT_PROJECT_VERSION = 180;/CURRENT_PROJECT_VERSION = 181;/g' Bitkit.xcodeproj/project.pbxproj

# Replace old marketing version (e.g. 2.0.6) with new (e.g. 2.0.7)
sed -i '' 's/MARKETING_VERSION = 2.0.6;/MARKETING_VERSION = 2.0.7;/g' Bitkit.xcodeproj/project.pbxproj
```

Commit and push:

```bash
git add Bitkit.xcodeproj/project.pbxproj
git commit -m "chore: version 2.0.7"
git push -u origin release-2.0.7
```

### Create PR

Create a PR targeting `master` with title `chore: bump version 2.0.7`. This PR stays open during QA and is merged post-release.

### Create Draft GitHub Release

Create the draft release early so auto-generated release notes are available during QA:

```bash
gh release create v2.0.7 \
  --title "v2.0.7" \
  --draft \
  --generate-notes \
  --notes-start-tag v2.0.6 \
  --target release-2.0.7
```

Send the draft link to whoever writes the user-facing release notes.

### Generate Store Release Notes

Write a concise user-facing summary (2-3 sentences) based on the auto-generated changelog. Translate into English, French, Spanish, Portuguese, and German. Save to `.ai/release-notes-{version}.md`:

```markdown
# Release Notes v2.0.7

## English
Summary of changes for end users.

## French
Résumé des modifications pour les utilisateurs.

## Spanish
Resumen de cambios para los usuarios.

## Portuguese
Resumo das alterações para os utilizadores.

## German
Zusammenfassung der Änderungen für Endnutzer.
```

Share this file for review. The English summary is also prepended to the draft GitHub release body.

These translated notes are later pasted into App Store Connect when submitting for review (step 4).

---

## 2. Build and Upload to TestFlight

### Option A: Manual (Xcode)

1. Open `Bitkit.xcodeproj` in Xcode
2. Select **Any iOS Device (arm64)** from the target dropdown
3. **Product -> Archive** (wait for the build to complete)
4. In the Archives window, select the new archive and click **Distribute App**
5. Choose **App Store Connect** distribution
6. After upload completes, go to [App Store Connect](https://appstoreconnect.apple.com/)
7. Select **Bitkit** app -> **TestFlight**
8. Once the build is processed and ready, set compliance:
   - Encryption: **"Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system"**
   - Distribute in France: **Yes**

The build is then automatically available for internal testing on TestFlight.

### Option B: CLI

Requires one-time setup of App Store Connect API credentials (see [CLI Prerequisites](#cli-prerequisites) below).

**Archive:**

```bash
xcodebuild archive \
  -project Bitkit.xcodeproj \
  -scheme Bitkit \
  -archivePath ./build/Bitkit.xcarchive \
  -configuration Release
```

**Export IPA:**

```bash
xcodebuild -exportArchive \
  -archivePath ./build/Bitkit.xcarchive \
  -exportPath ./build/export \
  -exportOptionsPlist ExportOptions.plist
```

**Upload to TestFlight:**

```bash
xcrun altool --upload-app \
  -f ./build/export/Bitkit.ipa \
  --type ios \
  --apiKey $APPSTORE_KEY_ID \
  --apiIssuer $APPSTORE_ISSUER_ID
```

After upload, set compliance in App Store Connect (same as manual path above).

---

## 3. QA

Test the build on TestFlight.

### Patching Issues During QA

If bugs are found and fixed in the release branch, you need to bump the build number, re-tag, and upload a new build to TestFlight. App Store Connect rejects duplicate build numbers, so every TestFlight upload must have a unique `CURRENT_PROJECT_VERSION`.

1. **Fix the issue** -- commit the fix to the release branch.

2. **Bump the build number** (`CURRENT_PROJECT_VERSION` only, not `MARKETING_VERSION`):
   ```bash
   sed -i '' 's/CURRENT_PROJECT_VERSION = 181;/CURRENT_PROJECT_VERSION = 182;/g' Bitkit.xcodeproj/project.pbxproj
   git add Bitkit.xcodeproj/project.pbxproj
   git commit -m "chore: build 182"
   git push
   ```

3. **Re-tag** the release (move the tag to the latest commit on the release branch):
   ```bash
   git tag -d v2.0.7
   git push origin :refs/tags/v2.0.7
   git tag -a v2.0.7 -m "v2.0.7"
   git push origin v2.0.7
   ```

4. **Update the draft GitHub release** to regenerate notes if needed.

5. **Build and upload to TestFlight again** (repeat step 2).

Repeat this cycle for each round of fixes. Keep incrementing the build number each time (182, 183, ...).

---

## 4. Submit for App Store Review

1. Go to [App Store Connect](https://appstoreconnect.apple.com/) -> **Apps** -> **Bitkit** -> **Distribution** tab
2. Click **+** (top left) to create a new version (e.g. 2.0.7)
3. Paste translated release notes from `.ai/release-notes-{version}.md` into **"What's new in this version"** for each language
4. Under **Build**, add the latest TestFlight build
5. Confirm **"Manually release this version"** is selected at the bottom
6. **Submit for Review**

---

## 5. Release Once Approved

Apple emails when the review is approved (usually less than a day).

1. Announce in the team channel that the release is approved and will go live unless there are objections
2. Log in to [App Store Connect](https://appstoreconnect.apple.com/) and release the version

---

## 6. Post-Release

1. **Merge the release branch** into `master` via the open PR (includes all patches and version bumps)
2. **Publish** the draft GitHub release
3. **Update the in-app updater**: [bitkit/releases/tag/updater](https://github.com/synonymdev/bitkit/releases/tag/updater)

---

## CLI Prerequisites

To use the CLI build and upload path, you need an App Store Connect API key.

### One-Time Setup

1. Go to [App Store Connect > Users and Access > Integrations > App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
2. Generate a new key -- only **Account Holder** or **Admin** roles can do this. App Managers and Developers need to ask an Admin to generate one and share the `.p8` file, Key ID, and Issuer ID.
3. Download the `.p8` private key file (only available once at generation time)
4. Place the key at:
   ```
   ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
   ```
5. Note your **Key ID** and **Issuer ID** from the App Store Connect page
6. Export them as environment variables (add to your shell profile):
   ```bash
   export APPSTORE_KEY_ID="YOUR_KEY_ID"
   export APPSTORE_ISSUER_ID="YOUR_ISSUER_ID"
   ```

### ExportOptions.plist

The repo includes an `ExportOptions.plist` at the root. It declares the export method (`app-store-connect`) and automatic signing. No credentials are stored in this file.

### Required Roles

The following App Store Connect roles have permission to deliver apps:
- Account Holder
- Admin
- App Manager
- Developer

See [Role Permissions](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions) for details.

---

## Automation

The `/release` command (available in Claude Code and Cursor via `.claude/commands/release.md` / `.cursor/commands/release.md`) automates steps 1 through draft release creation:

1. Reads current version from `project.pbxproj`
2. Prompts for the new version (patch/minor/major)
3. Creates the release branch and bumps version
4. Commits, pushes, and creates the version bump PR
5. Creates tag and draft GitHub release
6. Optionally archives and uploads to TestFlight via CLI

Steps 3-6 (QA, App Store submission, release, post-release) remain manual.
