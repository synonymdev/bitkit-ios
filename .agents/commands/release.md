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

Set `{changelogTarget}`:
- If `{baseRef}` is `master`: `next`
- Otherwise: `hotfix`

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

Finalize changelog after the release branch contains all release commits:

```bash
scripts/collect-changelog.sh --target {changelogTarget}
```

Read `CHANGELOG.md` and check whether `## [Unreleased]` has any entries beneath it after collecting fragments.

**If entries exist:**
1. Replace `## [Unreleased]` with `## [{newVersionName}] - {YYYY-MM-DD}` (today's date)
2. Insert a fresh empty `## [Unreleased]` section above the new version heading
3. Update the compare link references at the bottom of the file:
   - Change `[Unreleased]` link to compare from `v{newVersionName}...HEAD`
   - Add a new `[{newVersionName}]` link comparing `v{oldVersionName}...v{newVersionName}`

**If no entries:** Print `⚠ CHANGELOG.md has no unreleased entries — continuing without changelog update.` and proceed.

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

If changelog collection updated `CHANGELOG.md` or deleted consumed fragments, run `git add CHANGELOG.md changelog.d` before the commit.

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

### Design

N/A — no UI changes.

### Preview

N/A

### QA Notes

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

Read the `## [{newVersionName}]` section from `CHANGELOG.md` as the primary source for release content. If that section is empty or was not created in Step 2c, fall back to fetching auto-generated release notes:

```bash
gh release view v{newVersionName} --json body --jq .body
```

Using the changelog entries (or auto-generated notes as fallback) as context, write a concise user-facing summary of the release (2-3 sentences max, no commit hashes or PR numbers, written for end users not developers). Focus on new features and important bug fixes. Omit chores, maintenance, refactoring, CI changes, and test coverage improvements — these are not relevant to App Store users. Translate the summary into 5 languages.

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
# Write store summary via heredoc (avoids shell expansion of apostrophes, $, backticks)
cat > /tmp/release-notes.md <<'NOTES_EOF'
## Store Release Notes

{english summary}

---

NOTES_EOF
# Append existing auto-generated notes
gh release view v{newVersionName} --json body --jq .body >> /tmp/release-notes.md
gh release edit v{newVersionName} --notes-file /tmp/release-notes.md
```

Print the path to the release notes file so the user can share it for review.

### 6b. Create Shared Google Doc for Release Notes

Publish the release notes as a Google Doc for store-notes review. The doc must be readable by everyone at Synonym ("Anyone at Synonym with the link can view"), matching earlier release notes docs. Do not look up people by display name — domain sharing and Slack `<@UID>` mentions handle distribution.

**Reuse if present.** Before creating, search Drive with `search_files` for an exact title (`mimeType = 'application/vnd.google-apps.document' and title = 'v{newVersionName} iOS'`). If one or more match, reuse the oldest match's `id` / `viewUrl` (do not create another doc). If several match, print a warning that duplicates exist and still reuse the oldest. **Sync check:** export the reused Doc with `download_file_content` (`fileId` = reused id, `exportMimeType`: `text/plain` — Google Docs do not export `text/markdown`). Normalize both the export and `.ai/release-notes-{newVersionName}.md` to comparable plain text before comparing: strip Markdown heading markers (`#` / `##` / …) from the local file, then collapse trivial whitespace on both sides. If they still differ, print `⚠ Reused Google Doc content differs from regenerated notes — open the Doc and replace its body with .ai/release-notes-{newVersionName}.md (Drive MCP cannot update Doc body in place)` and continue with the existing URL. Then skip to share/verify below (re-apply domain share only if missing).

**Otherwise create the doc** with the Google Drive MCP `create_file` tool. Drive converts Markdown into a native Google Doc, so pass the notes file verbatim:
- `title`: `v{newVersionName} iOS`
- `contentMimeType`: `text/markdown`
- `textContent`: full contents of `.ai/release-notes-{newVersionName}.md`

Store the returned `id` and `viewUrl`.

**Share with the Synonym domain.** The Drive MCP `share_file` tool only accepts user/group emails, so use Composio's Google Drive toolkit instead (`COMPOSIO_SEARCH_TOOLS` → `COMPOSIO_MULTI_EXECUTE_TOOL`, tool `GOOGLEDRIVE_CREATE_PERMISSION`):
- `file_id`: the document id
- `type`: `domain`
- `domain`: `synonym.to`
- `role`: `reader`

Do not share with individual emails and never use `type: anyone` (public).

**Verify** with the Google Drive MCP `get_file_permissions`: the result must contain a permission with `type: domain`, `domain: synonym.to`, `role: reader` (domain permissions use `domain`, not `emailAddress`).

**Fallbacks (never block the release on this step):**
- Google Drive MCP unavailable: print `⚠ Google Drive MCP unavailable — create the doc manually from .ai/release-notes-{newVersionName}.md` and continue with sharing status `not created`.
- Composio has no active `googledrive` connection: keep the doc and print `⚠ Domain sharing not applied — open the doc, Share → General access → "Synonym" → Viewer`, then continue with sharing status `created, domain share pending`.
- Share succeeded but verification does not show the domain permission: print the same manual-share warning and continue with sharing status `created, domain share pending`.

Store the doc URL and sharing status (`shared with Synonym` | `created, domain share pending` | `not created`) for the summary.

### 6c. Prepare #bitkit-native Slack Draft (local only)

Prepare a footer-free Slack announcement for the team in `#bitkit-native` (`C07BJ7DNPCG`). **Do not post to Slack in this step** — write the local file only. Posting happens after TestFlight (see **Post Slack** after step 7). **Default:** wait until both RCs are ready, then one complete parent+reply. **Rare:** single-platform hotfix — post for this platform only (see 7b). **Never** create a Slack draft or channel message that contains `TODO`. Mentions in the posted draft must use `<@UID>` from the Mentions roster below — never resolve recipients by display name.

**Write the local draft** to `.ai/slack-release-{newVersionName}.md` (create `.ai/` if needed). Format: Slack MCP markdown (`- ` lists, `[text](url)` links, `<@UID>` mentions). Fill this platform from the current release; fill the sibling from its release branch / PR / tag / Google Doc / GH APK when known. Incomplete sibling fields may stay as `TODO` **in this local file only**.

Template (iOS is this platform; Android is the sibling):

```markdown
# Slack draft — #bitkit-native — Release {newVersionName}

Format: Slack MCP markdown (`- ` lists, `[text](url)` links, `<@UID>` mentions).
Post via `slack_send_message_draft` only (never `slack_send_message`).
Send each draft from the Slack app, not the Cursor widget.
Do not post until both RCs are ready (no TODO in the Reply body).

## Thread parent

Release `{newVersionName}` :thread:

## Reply

Release candidates:
- iOS {newVersionName} ({newBuildNumber}) - available in TestFlight ([github.com/synonymdev/bitkit-ios/releases](https://github.com/synonymdev/bitkit-ios/releases))
- Android {newVersionName} ({Android build}) - available on [github.com/synonymdev/bitkit-android/releases](https://github.com/synonymdev/bitkit-android/releases)

cc: <@U04NN8MV2GY> <@U03DQKN95BK>
cc: <@U031TCP84D8> <@U06UXSF134N> for design review

Proposed Store Release notes:
- Android: [v{newVersionName} Android]({Android Google Doc URL})
- iOS: [v{newVersionName} iOS]({iOS Google Doc URL from 6b})

cc: <@U07D3A8RSPN>

Please find GH release notes for both platforms for detailed changes:
- [github.com/synonymdev/bitkit-android/releases](https://github.com/synonymdev/bitkit-android/releases)
- [github.com/synonymdev/bitkit-ios/releases](https://github.com/synonymdev/bitkit-ios/releases)

Version bump PRs (release branches, merged into master after the store release):
- Android: [{Android PR URL label}]({Android PR URL})
- iOS: [{iOS PR URL label}]({iOS PR URL from step 4})

These builds will be used for testing following the [testing framework](https://docs.google.com/spreadsheets/d/10_DufEPwKUCExkXF-jTY7njE0mh5ZspwhRw42NBBd-o).

## Mentions

- U04NN8MV2GY Jean-Christophe
- U03DQKN95BK Pav
- U031TCP84D8 Aldert
- U06UXSF134N Oliver Toledo
- U07D3A8RSPN Jacobo
```

Print the path to the local draft. Store it for the summary. Slack posting is deferred until after TestFlight.

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

### 7b. Post Slack (both RCs, or rare single-platform hotfix)

If the user skipped TestFlight above, ask whether build `{newBuildNumber}` is already processing/available on TestFlight before treating iOS as ready. If not on TestFlight yet, treat as not ready (same ask as sibling-not-ready below).

**Both ready** (default) means all of the following (no `TODO` left in the Reply body):
- iOS: build `{newBuildNumber}` is on TestFlight (or uploading/processing after step 7), version-bump PR URL known, store-notes Google Doc URL known.
- Android: `v{newVersionName}` GH draft has the APK, versionCode known, version-bump PR URL known, store-notes Google Doc URL known when the Android doc was created.

Refresh `.ai/slack-release-{newVersionName}.md` with finalized values.

**If the sibling is not ready yet** (or this platform is not on TestFlight yet): ask the user:
1. `Wait for sibling` (default) — print `⏸ Slack not posted — waiting until Android {newVersionName} APK is on the GH draft release (and its doc/PR are known). Local draft: .ai/slack-release-{newVersionName}.md`. Do not call Slack. Continue the release.
2. `Single-platform hotfix` (rare) — rewrite the Reply to **iOS-only**: drop Android RC / doc / PR lines (do not leave `TODO`); open with a clear iOS-only/hotfix cue in the first line of the reply (e.g. `iOS-only hotfix:`). Then post per the steps below. Only offer this when this iOS build is (or will be) on TestFlight.
3. `Skip Slack` — print a manual reminder and continue.

**If ready to post** (both platforms filled, or user chose single-platform hotfix): post as Slack drafts (one attached draft per channel at a time). **Never call `slack_send_message`** — it always appends `Sent using Cursor`. Use `slack_send_message_draft` only; the user must send each draft **from the Slack app** (Cursor widget also adds the footer).

1. Locate the parent with `slack_read_channel` on `C07BJ7DNPCG` (`slack_read_channel` returns **top-level messages only** — not reply bodies). If `Release \`{newVersionName}\` :thread:` is already posted and does **not** include `Sent using`, reuse its `ts` and skip to step 4. Otherwise create the **parent** draft in `#bitkit-native` (`channel_id`: `C07BJ7DNPCG`) with body exactly: `Release \`{newVersionName}\` :thread:`
2. Tell the user: send that draft **from the Slack app** (not the Cursor widget), then confirm when done — or proceed to poll.
3. Poll with `slack_read_channel` on `C07BJ7DNPCG` every **5 seconds** until that parent appears (no `Sent using`). Cap at ~2 minutes. If not found after the cap: ask the user whether the parent was posted (`Yes, continue` / `Skip Slack and continue`). On Yes, locate the parent once more; on Skip, print a manual-post reminder and continue the release (do not keep polling).
4. **Dedup before drafting a reply.** Call `slack_read_thread` with `channel_id` `C07BJ7DNPCG` and `message_ts` set to the parent `ts` from steps 1–3. Inspect reply bodies:
   - Complete dual-platform reply already exists (no `TODO`, finalized Android **and** iOS RC / doc / PR lines) → skip Slack; print that the announcement is already posted.
   - Existing reply is a single-platform hotfix for the **same** platform as this run (`iOS-only hotfix:` here, or only this platform's RC line) → skip.
   - Existing reply is a single-platform hotfix for the **other** platform (or only one RC line) and this run is dual-ready → do **not** treat it as dual-complete; continue to step 5 with the dual-platform Reply body.
   - No reply yet → continue to step 5.
5. Create the **reply** draft with `thread_ts` set to that parent's message `ts`, body = the `## Reply` section from `.ai/slack-release-{newVersionName}.md` (markdown body only, no headings). The body must contain **no** `TODO`.
6. Tell the user: open the thread in `#bitkit-native` and send the reply draft **from Slack**.

**Fallbacks (never block the release):** Slack MCP unavailable → print `⚠ Slack draft not created — post manually from .ai/slack-release-{newVersionName}.md when ready` and continue.

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
Release notes doc: {Google Doc URL or "(not created)"} ({sharing status from 6b})
Slack draft: .ai/slack-release-{newVersionName}.md ({posted parent+reply | deferred — waiting for sibling RC | single-platform hotfix posted | already posted | skipped})

Next steps:
- If Slack was deferred: post once the sibling RC is ready, or choose single-platform hotfix if this cut ships alone (no TODOs in the reply)
- Send any #bitkit-native Slack drafts from the Slack app (if not already)
- Share the release notes doc with Jacobo for review (if domain share is still pending, apply it first)
- Build and upload to TestFlight (if not done above)
- Set TestFlight compliance after build processes
- QA on TestFlight
- If patching the release branch: increment only the build number, re-tag, and re-upload (see Docs/RELEASE.md)
- Submit for App Store review when QA passes
- Publish the draft release on GitHub after App Store release
- Merge release branch PR into master
```
