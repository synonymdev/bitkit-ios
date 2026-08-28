# Journeys

A journey is an XML-specified walkthrough of app behaviour, evaluated by an agent driving a running
simulator. They are developer-assistance specs: they give an agent a reliable route through a flow so
it can reproduce a bug, check a change by hand, or show you what a screen does today.

These are ported from [`bitkit-android/journeys`](https://github.com/synonymdev/bitkit-android/tree/main/journeys)
and deliberately keep the same file names, journey names and `<action>` prose so the two platforms
stay diffable. Only the platform mechanics differ — `adb` becomes `xcodebuildmcp`, and Android
`testTag`s become iOS `accessibilityIdentifier`s (the vocabulary is shared; see [Identifiers](#identifiers)).

**Journeys are not a QA gate.** They are agent-evaluated and non-deterministic, nothing runs them in
CI, and there is no runner wired up for them yet — `ai-device-tests.yml` runs `TrezorBridgeDashboardUITests`
and does not read `journeys/`. Treat a journey as a well-written description of a flow, not as an
authority on what the app owes you.

A journey that no longer matches the app is most likely **stale**, not evidence of a bug. The corpus
is new on iOS and has not been run end to end, so when the two disagree the first assumption should be
that the spec drifted. Say what you found, update the journey, and only escalate when you have
separately confirmed the app is wrong.

## Format

```xml
<journey name="short lowercase name">
  <description>What this proves, and the preconditions needed to prove it.</description>
  <actions>
    <action>Tap the Spending balance card on the home screen</action>
    <action>Verify the spending amount screen (id "SpendingAmount") is visible</action>
  </actions>
</journey>
```

- Evaluate `<action>` elements in order, and report each one. An action that does not hold is worth
  reporting as-is — it may be a stale step as easily as a real problem.
- An action beginning with "check" or "verify" is an expectation about the **current** screen —
  inspect it, do not scroll or interact to satisfy it.
- An action that specifies several interactions is split into sub-actions and evaluated individually.
- If an interaction cannot be performed as written, say so and stop rather than improvising a route
  around it — the point is to find out where the written route stopped matching the app.
- If the app crashes, exits or freezes, evaluation stops there. That one *is* worth escalating.

## Running a journey

Drive the simulator with the XcodeBuildMCP CLI (see the Agent CLI section in `AGENTS.md`):

```bash
xcodebuildmcp simulator build-and-run                 # build, install, launch, capture logs
xcodebuildmcp simulator snapshot-ui                   # semantic snapshot with elementRef targets
xcodebuildmcp ui-automation tap --element-ref e12     # tap one ref from the latest snapshot
xcodebuildmcp ui-automation type-text --element-ref e8 --text "..."
xcodebuildmcp ui-automation wait-for-ui --predicate textContains --text "Spending Balance Maximum"
xcodebuildmcp ui-automation wait-for-ui --identifier SpendingAmount --predicate exists
xcodebuildmcp simulator screenshot                    # only when a snapshot cannot settle a question
```

Assert on identifiers rather than copy where one exists — `--identifier X --predicate exists` fails
fast on a typo, while a text predicate silently depends on the current translation. Note the flag
shape: `--predicate textContains --text "..."`, not `--text-contains`.

Refresh the snapshot after navigation, scrolling, sheet changes, or any obvious layout change —
`elementRef`s from a stale snapshot are not reusable.

**Some controls never appear as snapshot targets.** Anything built on `.onTapGesture` rather than a
`Button` — the All Activity tag filter (`TagsPrompt`) is one — resolves by identifier but is absent
from the target list. If a control the journey names is missing from `snapshot-ui`, check it with
`--identifier X --predicate exists` before concluding it is gone.

**Identifiers built from localized text are English-only.** `SegmentedControl` derives its identifier
from the tab's display name, so `Tab-all` is `Tab-todas` when the app runs in Spanish. Journeys that
name a `Tab-*` identifier assume an English device.

Prefer `snapshot-ui` over screenshots: it names elements by their accessibility identifier, which is
what the journeys assert on, and it avoids the image-size limits the Android runner has to work around.

## Backend preconditions

Most journeys need regtest and a reachable LSP. Start the stack from a sibling `bitkit-docker`
checkout on `main` (same stack `Docs/AI_DEVICE_TESTS.md` uses):

```bash
cd /path/to/bitkit-docker
docker compose up -d
```

Build the app with the E2E compilation condition so it targets the local backend:

```bash
xcodebuildmcp simulator build-and-run \
  --extra-args "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) E2E_BUILD"
```

Fund a wallet before any amount journey — with a zero balance the caps fall back to the global
maximum and the journeys pass for the wrong reason:

```bash
../bitkit-android/lsp POST /regtest/chain/deposit '{"address":"<savings addr>","amountSat":100000}'
../bitkit-android/lsp POST /regtest/chain/mine '{"count":3}'
```

`deposit` prints the funding txid; **`mine` prints nothing on success** and signals only through its
exit status, so an empty response there is not a failure. Give the wallet ~20s to sync before
reading the balance.

**The `lsp` helper is borrowed from the sibling Android checkout.** It is the `blocktank-api` plugin's
script, and there is no iOS copy yet — #694 tracks porting it. The relative path assumes
`bitkit-android` is cloned next to this repo, which is the usual layout here; the hardware-wallet
journeys already reach for `../bitkit-docker` the same way. If you do not have that clone, fund the
wallet however you normally do against regtest and skip the helper.

## Identifiers

iOS uses `accessibilityIdentifier`; Android uses Compose `testTag`. The vocabulary is shared, so a
journey usually names the same string on both platforms. Where a container needs to be queryable,
iOS pairs the identifier with `.accessibilityElement(children: .contain)`.

Known naming differences:

| Concept | Android testTag | iOS accessibilityIdentifier |
| --- | --- | --- |
| Send amount screen | `send_amount_screen` | `SendAmount` |
| Send available balance | `AvailableAmount` and `available_balance` (Android emits both) | `AvailableAmount` |
| Send max | `SendAmountMax` | *(no button — tap `AvailableAmount`)* |
| External amount available | — | `ExternalAmountAvailable` |

Everything else — `N0`–`N9`, `N000`, `NDecimal`, `NRemove`, `SpendingAmount*`, `SpendingAdvanced*`,
`External*`, `Hardware*`, `Widget*` — matches Android exactly.

## Suites

| Suite | Journeys | Notes |
| --- | --- | --- |
| [amount-limits](amount-limits) | 4 | Number pad caps on all four amount screens |
| [widgets](widgets) | 2 | Widgets intro and add-widget flow |
| [notification-permission](notification-permission) | 4 | "Set up in background" toggles |
| [cjit-notifications](cjit-notifications) | 3 | Adapted — iOS notification copy differs from Android |
| [hardware-wallet](hardware-wallet) | 15 | Trezor over Bridge; see `Docs/AI_DEVICE_TESTS.md` |

## Not ported

**`deeplinks` (2 journeys).** The Android journeys exercise `bitkit://screen/...` routing with a
dev-mode gate and a cold-start replay. iOS registers the `bitkit` URL scheme (`Bitkit/Info.plist`)
but `onOpenURL` in `Bitkit/MainNavView.swift` only handles web URLs, Pubky auth callbacks and
payment URIs — there is no screen or sheet deeplink router, and no dev-mode gate to test. These
journeys are blocked on the feature existing, not on the harness.

## Porting from Android

When you port an Android feature, port its journeys too — see the Journeys section in `AGENTS.md`.

A journey is a shared spec, so a behaviour that is meant to match Android can be checked by running
the same file on both sides: `xcodebuildmcp` here, the `android` CLI against a `bitkit-android`
checkout there (`android layout` is the `snapshot-ui` equivalent). A disagreement is worth writing
down — as an intentional platform difference, or as something to look into — but it is not by itself
a bug report. `AGENTS.md` has the commands.
