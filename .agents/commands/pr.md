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

### 3. Gather Context
- Get current branch name: `git branch --show-current`
- Extract repo identifier: `git remote get-url origin | sed 's/\.git$//' | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#'` (e.g., `synonymdev/bitkit-ios`)
- Read PR template from `.github/pull_request_template.md`
- Fetch 10 most recent PRs (open or closed) from the extracted repo for writing style reference
- Run `git log $base..HEAD --oneline` for commit messages
- Run `git diff $base...HEAD --stat` for understanding scope of changes
- List the journeys the branch adds or updates: `git diff --name-only --diff-filter=d $base...HEAD -- journeys | grep '\.xml$'`

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
- One bullet per change under `### Description`: what changed and why, in one sentence each (`Adds X so that Y`, `Fixes X because Y`)
- Base content around all commit messages in the branch
- Use branch name as the conceptual anchor
- Match writing style of recent PRs
- Focus on functionality over technical details
- Avoid excessive bold formatting like `**this:** that`
- Minimize code and file references like `TheClassName` or `someFunctionName`, `thisFileName.ext`
- Exception: for refactoring PRs (1:10 ratio of functionality to code changes), more technical detail is ok

**Out of Scope (`#### Out of Scope`, a subsection at the end of `### Description`):**
- Required for `feat`, `fix`, and `refactor` PRs: one bullet per item the PR deliberately leaves out, with the file or area it covers when there is one (`path/or/area: item`); `None.` when nothing is left out
- Not needed for version bumps, changelog-only changes, dependency bumps, and release PRs; other `chore`, `docs`, and `test` PRs include it at the author's discretion
- Derive candidates from commit messages, linked issues, and review discussion (deferred follow-ups, adjacent behaviour left unchanged); ask the user when unsure
- Reviewers, human and automated, read the bullets as the author's non-goals

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
- Under `#### Journeys`, list every journey the branch adds or updates (Step 3), one per line as an unchecked checkbox (`- [ ] `), then `new` or `updated`, then the bare journey file name in backticks, then a dash and what the journey proves.
- List a journey as `temporary` only when the user asks for one in custom instructions: a reproduction that needs a code change or data that will not exist on master. Put its XML, and any code change as a `.diff`, in a collapsed `<details>` block under its line, and do not commit it. Never add one unasked; at most, suggest it to the author and ask whether they agree.
- Reference journeys by bare file name only, never the full path. Only when two listed journeys share the same name, prefix the shortest leading path segment(s) that disambiguate them, the same rule as test files.
- A PR with a user-visible change adds or updates the journey that proves it, and any journey whose route the diff changes; list them all. Reviewers drive the listed journeys on a device.
- `#### Journeys` takes one of two empty values: `N/A — no user-visible behaviour change.` when the diff changes nothing a user can see, and `N/A — not drivable; see Manual Tests.` when it does but every flow it touches needs a capability the Capabilities table in `journeys/README.md` does not list. The second value requires a matching step under `#### Manual Tests`.
- Leave every checkbox under `#### Journeys` and `#### Manual Tests` unchecked; the reviewer ticks a line after driving it on the PR head.
- When the diff changes user-visible behaviour and no journey covers it, stop and report the flows that need a journey. A flow the Capabilities table cannot provide is the exception: record it under `#### Manual Tests` naming the missing capability instead of stopping.
- Under `#### Manual Tests`, write a step only when it needs a capability the Capabilities table in `journeys/README.md` does not list, and name that capability in the step. Everything a journey can drive belongs under `#### Journeys`.
- Keep local verification commands, `xcodebuild`, Swift tests, SwiftFormat, translation validation, unit tests, build passes, cargo test, cargo clippy, npm test, typecheck, CI coverage, or similar automated checks out of `#### Manual Tests`; summarize them under `#### Automated Checks` when they add useful context.
- Use `#### Automated Checks` for a flat list of automated verification evidence, in the keyword order `added`, `updated`, `removed`, `ran`: the keyword, the bare test file name in backticks, then a dash and the behaviour it proves.
- Reference test files by bare file name only (e.g. `TransferViewModelTests.swift`), never the full path. Only when two referenced test files share the same name, prefix the shortest leading path segment(s) that disambiguate them (e.g. `BitkitTests/SendTests.swift` vs `BitkitUITests/SendTests.swift`).
- For a `removed` item, state why the coverage was removed.
- Use `ran` only for checks CI does not run. Do not list standard CI or PR bot commands just because they run for every PR.
- List raw commands under `ran` only when they were run locally, are non-standard, use special flags or environment values, validate workflow behavior, or explain a meaningful verification gap.
- For workflow behavior validation, include `(after merge)` in the automated check item because workflow changes only take effect for PRs opened after the workflow update merges.
- If no step needs a missing capability, write `N/A` under `#### Manual Tests`.
- If no automated checks were run and no automated coverage changed, write `N/A` under `#### Automated Checks`.
- Write manual tests using this template:
  ```md
  - [ ] {optional_condition + →} {action} → {expectation} — {missing capability} not in Capabilities
  ```
- Use `regression:` for regression checks, positioned at the start of the action.
- Always use `→` to denote navigation, for example `Send → Amount`; the last `→` introduces the expectation.
- Use screen names from code, formatted as separate words without the `View` or `Screen` suffix, for example `FundReceiveView` becomes `Fund Receive`.
- Use short-form wording like `in-sheet` for sheet screens, `nav` for navigation, `back` for back nav, and `LN` for Lightning Network.

**For library repos (has `bindings/` directory or `Cargo.toml`):**
These repos have no `journeys/`, so the walkthrough stays under `#### Manual Tests` and needs no capability reason. Structure it around integration validation only. Automated checks belong under `#### Automated Checks`.

Example:
```
### QA Notes
#### Manual Tests
- [ ] Consumer app → exercise the updated binding flow → behavior matches the previous release
- [ ] `regression:` iOS integration screen → trigger the changed API path → no crash or stale data
#### Automated Checks
- added `FooBindingTests.swift` — covers the updated iOS API path
- ran `cargo test --all-features` — binding round-trip CI does not build
```

Concrete style target:
```md
### QA Notes
#### Journeys
- [ ] new `send-amount-over-balance.xml` — error shows before the 15 s timeout
- [ ] updated `lightning-transfer-detail.xml` — Connection opens Channel Detail
#### Manual Tests
- [ ] Pair a Trezor over BLE → Home shows the hardware wallet card — BLE pairing not in Capabilities
#### Automated Checks
- added `TransferViewModelTests.swift` — rejects amounts over the spending balance
- updated `SendFlowTests.swift` — fixed-amount invoice skips the Amount screen
- removed `OldFlowTests.swift` — flow no longer exists
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
