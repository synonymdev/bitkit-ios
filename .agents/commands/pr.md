---
description: Create a PR on GitHub for the current branch
argument_hint: "[branch] [--dry] [--draft]"
allowed_tools: Bash, Read, Glob, Grep, Write, AskUserQuestion, mcp__github__create_pull_request, mcp__github__list_pull_requests, mcp__github__get_file_contents, mcp__github__issue_read
---

Create a PR on GitHub using the `gh` CLI for the currently checked-out branch.

**Examples:**
- `/pr` - Interactive mode, prompts for PR type
- `/pr master` - Interactive with explicit base branch
- `/pr --dry` - Generate description only, save to `.ai/`
- `/pr --draft` - Create as draft PR
- `/pr develop --draft` - Draft PR against non-default branch

## Steps

### 1. Check for Existing PR
Run `gh pr view --json number,url 2>/dev/null` to check if a PR already exists for this branch.
- If PR exists: Output `PR already exists: [URL]` and stop
- If no PR: Continue

### 2. Parse Arguments
- `--dry`: Skip PR creation, only generate and save description
- `--draft`: Create PR as draft
- First non-flag argument: base branch (default: auto-detected, see Step 2.5)
- **If no flags provided**: Use `AskUserQuestion` to prompt user:
  - Open PR (create and publish)
  - Draft PR (create as draft)
  - Dry run (save locally only)

### 2.5. Determine Base Branch
If no base branch argument provided, detect the repo's default branch:
- Run: `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'`
- Use result as default (typically `main` or `master`)
- If command fails, fall back to `master`

### 2.6. Regenerate the Journeys Index
- Run `python3 scripts/journeys_index.py`
- If `journeys/index.json` changed, commit it as `chore: update journeys index`
- If it reports an identifier that no source file declares, stop and report the journey and the identifier

### 3. Gather Context
- Get current branch name: `git branch --show-current`
- Extract repo identifier: `git remote get-url origin | sed 's/\.git$//' | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#'` (e.g., `synonymdev/bitkit-ios`)
- Read PR template from `.github/pull_request_template.md`
- Fetch 10 most recent PRs (open or closed) from the extracted repo for writing style reference
- Run `git log $base..HEAD --oneline` for commit messages
- Run `git diff $base...HEAD --stat` for understanding scope of changes
- List the journeys the branch adds or updates: `git diff --name-only --diff-filter=d $base...HEAD -- journeys | grep '\.xml$'`
- List the journeys whose route the branch may change: the `journeys/index.json` entries that name an identifier declared in a file from `git diff --name-only $base...HEAD`

### 4. Extract Linked Issues
Scan commits for issue references:
- Pattern to match: `#123` (just the issue number reference)
- Extract unique issue numbers: `git log $base..HEAD --oneline | grep -oE "#[0-9]+" | sort -u`
- Fetch each issue title: `gh api "repos/$REPO/issues/NUMBER" --jq '.title'` (using repo from Step 3)
- These will be used to start the PR description with linking keywords (see Step 6)

### 5. Identify Suggested Reviewers
Find potential reviewers based on:
- `.github/CODEOWNERS` file patterns (if exists)
- Recent contributors to changed files: `git log --format='%an' -- $(git diff $base..HEAD --name-only) | sort | uniq -c | sort -rn | head -3`
- Exclude the current user from suggestions

### 6. Generate PR Description
Starting from the template in `.github/pull_request_template.md`:

**Title Rules:**
- Format: `prefix: title` (e.g., `feat: add user settings screen`)
- Keep under 50 characters
- Use branch name as concept inspiration
- Prefixes: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`

**Issue Linking (at the very start):**
If linked issues were found in commit messages, begin the PR description with linking keywords:
- Use `Fixes #123` for bug fixes
- Use `Closes #123` for features/enhancements
- One per line, before the "This PR..." opening separated by one empty line
- Reference: https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/using-keywords-in-issues-and-pull-requests

Example:
```
Fixes #528
Closes #418

This PR adds support for...
```

**Opening Format:**
- Single change: Start with "This PR [verb]s..." as a complete sentence
  - Example: `This PR adds a Claude Code /pr command for generating PRs.`
- Multiple changes: Start with "This PR:" followed by a numbered list
  - Example:
    ```
    This PR:
    1. Adds a Claude Code /pr command for generating PRs
    2. Fixes issue preventing Claude Code reviews to be added as PR comments
    3. Updates reviews workflow to minimize older review comments
    ```
- Each list item should start with a verb (Adds, Fixes, Updates, Removes, Refactors, etc.)

**Description Rules:**
- Base content around all commit messages in the branch
- Use branch name as the conceptual anchor
- Match writing style of recent PRs
- Focus on functionality over technical details
- Avoid excessive bold formatting like `**this:** that`
- Minimize code and file references like `TheClassName` or `someFunctionName`, `thisFileName.ext`
- Exception: for refactoring PRs (1:10 ratio of functionality to code changes), more technical detail is ok

**Custom Instructions:**
When the user provides custom instructions after `--`:
- Parse any referenced commit SHAs and read their full messages
- Focus the description content on areas the user emphasizes
- Structure QA Notes according to user's specific manual testing instructions and automated coverage notes
- Custom instructions take priority over default generation rules for sections they address
- Preserve exact manual testing steps provided by the user (don't summarize or omit details)
- If custom instructions include automated checks or coverage notes, place them under `#### Automated Checks`

**Design:**
- Include a `### Design` section when the PR template contains a `### Design` heading.
- For user-visible UI changes with an existing design, link the relevant Figma frames, starting with the latest `Bitkit - Handoff vNN` page in https://www.figma.com/design/ltqvnKiejWj0JQiqtDf2JJ/.
- For user-visible UI changes with no available design, including new features, write `N/A — no design available.`
- For changes without user-visible UI changes, write `N/A — no UI changes.`
- If the relevant Figma frame is missing or uncertain, state the uncertainty.
- Never invent a Figma link or require a new design.
- Reviewers may make at most one advisory request per PR when an existing-design UI PR omits its Figma link.
- `N/A — no UI changes.` needs no review request; `N/A — no design available.` may receive the single advisory clarification.
- Missing Figma links never block approval, CI, PR creation, or review readiness.

**QA Notes / Validation:**
- QA Notes separate actionable human QA instructions from automated verification coverage.
- Always use this structure:
  ```md
  ### QA Notes
  #### Journeys
  #### Manual Tests
  #### Automated Checks
  ```
- Under `#### Journeys`, list every journey the branch adds or updates (Step 3) as a list item with its repo path, e.g. `journeys/widgets/widgets-intro.xml`.
- Write `N/A — no user-visible behaviour change.` under `#### Journeys` only when the diff changes no user-visible behaviour. When it does and the branch adds or updates no journey, stop and report the flows that need one.
- Check each journey whose route the branch may change (Step 3) against the diff. If one no longer matches, stop and report it; the branch updates that journey first.
- Under `#### Manual Tests`, keep only what a journey cannot express, such as hardware, push notifications, or a companion app, and end each item with the reason. Write no manual test for a flow a listed journey covers.
- Keep local verification commands, `xcodebuild`, Swift tests, SwiftFormat, translation validation, unit tests, build passes, cargo test, cargo clippy, npm test, typecheck, CI coverage, or similar automated checks out of `#### Manual Tests`; summarize them under `#### Automated Checks` when they add useful context.
- Use `#### Automated Checks` to summarize automated verification evidence, prioritizing coverage added, modified, or removed with file paths and a short explanation.
- For removed automated coverage, state why it was removed.
- Do not list standard CI or PR bot commands as checkbox items just because they run for every PR. If standard CI coverage is worth mentioning, summarize it in one sentence.
- List raw commands only when they were run locally, are non-standard, use special flags or environment values, validate workflow behavior, or explain a meaningful verification gap.
- For workflow behavior validation, include `(after merge)` in the automated check item because workflow changes only take effect for PRs opened after the workflow update merges.
- If no actionable manual validation exists, write `N/A` under `#### Manual Tests`.
- If no automated checks were run and no automated coverage changed, write `N/A` under `#### Automated Checks`.
- Write manual tests using this template:
  ```md
  - [ ] **{numbering}.** {optional_condition + →} {screen_action} → {next_screen_action}: expectation — {reason a journey cannot express it}
  ```
- Use a list of unchecked checkboxes for each individual test.
- Use a numbered prefix for each test, in bold, for example `**1.**`, `**2.**`.
- Use `regression:` for regression checks, positioned after the numbering.
- Use sub-lists for variations of the same test.
- Use letter suffixes in numbering for each variation when a test has a sub-list, for example `**3a.**`, `**3b.**`.
- Always use `→` to denote navigation, for example `Send → Amount`.
- Use screen names from code, formatted as separate words without the `View` or `Screen` suffix, for example `FundReceiveView` becomes `Fund Receive`.
- Use short-form wording like `in-sheet` for sheet screens, `nav` for navigation, `back` for back nav, and `LN` for Lightning Network.

**For library repos (has `bindings/` directory or `Cargo.toml`):**
Structure manual QA around integration validation only. Automated checks belong under `#### Automated Checks`.

Example:
```
### QA Notes
#### Manual Tests
- [ ] **1.** Consumer app → exercise updated binding flow: behavior matches previous release.
- [ ] **2.** `regression:` iOS integration screen → trigger changed API path: no crash or stale data.
#### Automated Checks
- Binding tests added: cover updated iOS API path in `bindings/ios/...`.
- CI: standard cargo and binding checks run by the PR bot.
```

Concrete style target:
```md
### QA Notes
#### Journeys
- `journeys/amount-limits/send-amount-over-balance.xml`
- `journeys/widgets/add-widgets-flow.xml`
#### Manual Tests
- [ ] **1a.** Physical device → Scanner → scan a printed fixed amount LN invoice QR: Send Confirm opens directly — needs a device camera.
  - [ ] **1b.** `regression:` Printed LNURL-pay QR: lands on Amount view — needs a device camera.
- [ ] **2.** Pubky Ring installed → Profile → sign in with Pubky Ring: profile shows as connected — needs the Pubky Ring app.
#### Automated Checks
- Unit tests added: cover invoice timeout handling in `BitkitTests/TransferViewModelTests.swift`.
- Unit tests modified: update channel navigation assertions in `BitkitTests/ChannelDetailsViewModelTests.swift`.
- Test coverage removed: delete stale mock-only assertions from `BitkitTests/OldFlowTests.swift` because the flow no longer exists.
- CI: standard build and test checks run by the PR bot.
```

**Preview Section (conditional):**
Only include if the PR template (`.github/pull_request_template.md`) contains a `### Preview` heading:
- Create placeholders for media: `IMAGE_1`, `VIDEO_2`, etc.
- Add code comment under each placeholder describing what it should show
- Example: `<!-- VIDEO_1: Record the send flow by scanning a LN invoice and setting amount to 5000 sats -->`

### 7. Save PR Description
Before creating the PR:
- Get next PR number: `gh api "repos/$REPO/issues?per_page=1&state=all&sort=created&direction=desc" --jq '.[0].number'` then add 1 (using repo from Step 3)
- Create `.ai/` directory if it doesn't exist
- Save to `.ai/pr_NN.md` where `NN` is the predicted PR number

### 8. Create the PR (unless --dry)
If not dry run:
```bash
gh pr create --base $base --title "..." --body "..." [--draft]
```
- Add `--draft` flag if draft mode selected
- If actual PR number differs from predicted, rename the saved file

### 8b. Changelog Fragments

If the PR is user-facing, verify the branch adds exactly one changelog fragment under `changelog.d/next/` or `changelog.d/hotfix/`.
Do not edit `CHANGELOG.md` in normal PRs.
If the PR was created (not dry run), rename any new changelog fragment whose filename does not start with the actual PR number to `<PR_NUMBER>.<category>.md`, preserving the category (`added`, `changed`, `deprecated`, `removed`, `fixed`, or `security`).
If any fragment was renamed, create a follow-up commit with message `chore: rename changelog fragment` and push it.

### 9. Output Summary

**If PR created:**
```
PR Created: [PR URL]
Saved: .ai/pr_NN.md

Suggested reviewers:
- @username1 (X files modified recently)
- @username2 (CODEOWNER)
```

**If dry run:**
```
Dry run complete
Saved: .ai/pr_NN.md

To create PR: /pr [--draft]

Suggested reviewers:
- @username1 (X files modified recently)
- @username2 (CODEOWNER)
```

**Media TODOs (only if Preview section was included):**
If the PR description includes a Preview section with media placeholders, append:
```
## TODOs
- [ ] IMAGE_1: [description]
- [ ] VIDEO_2: [description]
```
List all media placeholders as TODOs with their descriptions.
