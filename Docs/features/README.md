# Feature map

Read `Docs/features/<x>.md` before changing or testing feature `x`. It names the screens and accessibility identifiers, the code that owns the feature, the journeys and e2e specs that drive it, what each proves, and what no test covers. A PR that changes a flow updates that flow's file in the same change; `node scripts/validate-feature-map.js`, run in CI, fails when a file names a repository path that no longer exists. File names match the Android feature map so one feature has the same name on both platforms.

## How the files are shaped

Every feature file has the same sections, in this order:

1. `What it does`
2. `How a user reaches it`: the tap path from launch, with `accessibilityIdentifier` values.
3. `Code`: views, view models, managers, services, sheet and route cases, as repo-root-relative paths.
4. `How to drive it`: journeys in `journeys/<folder>/` by file name, `bitkit-e2e-tests` specs by path and test tag, and the regtest, `bitkit-docker` and `E2E_BUILD` preconditions.
5. `What proves it`: the end state on screen, identifier, toast or activity item.
6. `Not covered by tests`: flows that neither journeys, e2e specs nor the unit and UI tests exercise.
7. `Gotchas`: platform differences, timing, skipped tests, stale journey steps.

Conventions:

- Paths are relative to the repo root. `bitkit-e2e-tests/...` is the sibling checkout `synonymdev/bitkit-e2e-tests` (Appium and WebdriverIO, shared by Android and iOS); specs live in `bitkit-e2e-tests/test/specs/`. There are no Maestro flows.
- The e2e specs do not cover every flow. CI tags: `@ios_gate` (iOS merge gate), `@ios_nightly` (iOS nightly shard), `*_staging` (staging shards); see `bitkit-e2e-tests/README.md`. Which specs the iOS workflows select is set in the app repo's `.github/workflows/` and the e2e repo's workflows; a spec without one of these tags was not confirmed to run on iOS CI.
- Journeys are XML walkthroughs an agent drives with `xcodebuildmcp`; nothing in CI runs them. Read `journeys/README.md` first (identifier differences from Android, backend setup, capabilities, not-ported list). A journey that disagrees with the app is more likely stale than a bug.
- Unit and UI tests live in `BitkitTests/` and `BitkitUITests/`; a feature file names them where they cover a flow.
- A statement in a file is verified in code or a test unless it is marked as unverified or "could not determine".
- Other prose docs are in `Docs/`.

## Index

Specs are in `bitkit-e2e-tests/test/specs/`.

| Feature | File | Journeys folder | E2E specs |
| --- | --- | --- | --- |
| Onboarding: create wallet, restore wallet, recovery mode | `onboarding.md` | `journeys/security/wallet-wipe-new-profile.xml`, `journeys/onchain-receive/restore-recent-receive-stays-silent.xml` | `onboarding.e2e.ts`, `migration.e2e.ts` (RN to native restore) |
| Home, wallet balances, suggestions | `home.md` | `journeys/home/` | none dedicated |
| Receive: onchain, lightning, CJIT | `receive.md` | `journeys/onchain-receive/`, `journeys/amount-limits/` (receive parts) | `receive.e2e.ts`, `receive-ln-payments.e2e.ts`, `lightning.e2e.ts`, `multiaddress.e2e.ts`, `numberpad.e2e.ts`, `mainnet/cjit.e2e.ts` |
| Send: onchain, lightning, scan, paste, manual entry | `send.md` | `journeys/amount-limits/` (send parts) | `send.e2e.ts`, `onchain.e2e.ts`, `lightning.e2e.ts`, `multiaddress.e2e.ts`, `numberpad.e2e.ts`, `mainnet/ln.e2e.ts` |
| LNURL: pay, withdraw, channel, auth, Lightning Address | `lnurl.md` | `journeys/lnurl/` | `lnurl.e2e.ts`, `mainnet/ln.e2e.ts`, `mainnet/probe.e2e.ts` (Android only) |
| Transfer: savings and spending, LSP channels, manual channels | `transfer.md` | `journeys/transfer/`, `journeys/amount-limits/` | `transfer.e2e.ts`, `mainnet/channel-order.e2e.ts` |
| Activity: list, detail, tags, boost | `activity.md` | none dedicated (`journeys/hardware-wallet/activity-*.xml` cover hardware rows) | `boost.e2e.ts`, `onchain.e2e.ts`, `lightning.e2e.ts`, `settings.e2e.ts` |
| Backup: recovery phrase, backup and restore | `backup.md` | none | `backup.e2e.ts`, `migration.e2e.ts`, `settings.e2e.ts` (`@settings_07`) |
| Security: PIN, biometrics, lock, wipe | `security.md` | `journeys/security/` | `security.e2e.ts`, `settings.e2e.ts` (`@settings_06`) |
| Settings: general, security entries, support, dev | `settings.md` | none | `settings.e2e.ts` |
| Settings, advanced: address types, coin selection, node, Electrum, RGS | `settings-advanced.md` | none | `settings.e2e.ts`, `multiaddress.e2e.ts` |
| Contacts | `contacts.md` | `journeys/contacts/`, `journeys/deeplinks/pubky-contact.xml` | `pubky-profile.e2e.ts`, `paykit.e2e.ts` |
| Pubky profile, Ring choice, Pubky Auth | `profile-pubky.md` | `journeys/profile/`, `journeys/pubky-profile/`, `journeys/pubky-auth/`, `journeys/pubky-marketplace/` | `pubky-profile.e2e.ts` |
| Widgets | `widgets.md` | `journeys/widgets/` | `widgets.e2e.ts` |
| Payment requests | `payment-requests.md` | `journeys/payment-requests/` | none |
| Subscriptions | `subscriptions.md` | `journeys/subscriptions/` | none |
| Notifications: permission, push, CJIT | `notifications.md` | `journeys/notification-permission/`, `journeys/cjit-notifications/` | none |
| App update | `app-update.md` | none | none |
| Deeplinks and URL schemes | `deeplinks.md` | `journeys/deeplinks/`, `journeys/pubky-auth/` | none |
| Hardware wallet: Trezor, Jade | `hardware-wallet.md` | `journeys/hardware-wallet/` | `hardware-wallet.e2e.ts` |
| Shop, Bitrefill, Buy Bitcoin, BTCPay | `shop.md` | none | none |
| Gift codes | `gift.md` | none | none |

`journeys/paykit-clock-changes.md` is a manual charter for device-clock changes; it is listed in `profile-pubky.md`.
