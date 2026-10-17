# Activity

Transaction history for the Bitkit wallet and watch-only hardware wallets: home list, All Activity with filters, detail, explorer detail, tags, contact assignment, Boost (CPFP/RBF), row icons. Hardware-specific activity checks are in `hardware-wallet.md`.

## What it does
- One list merges Lightning and on-chain items. Home and All Activity query `walletId: nil` (the Bitkit wallet plus hardware wallets, `ActivityListViewModel.syncState`); Savings and Spending screens list on-chain or Lightning items of the Bitkit wallet; the hardware screen lists that wallet only.
- Home (`ActivityLatest`) shows up to `ActivityDisplayConstants.maxHomeActivityItems` (4) rows; 3 on small screens, fewer when hardware tiles, the transfer banner or the widgets hint take slots. Button `ActivityShowAll` opens All Activity.
- All Activity (`AllActivityView`): search text (300 ms debounce), tabs All/Sent/Received/Other, tag filter, date-range filter. `resetFilters()` runs on appear.
- Tabs: Sent and Received exclude on-chain transfers; Other is on-chain `isTransfer` only (Lightning never) (`filterActivitiesByTab`).
- Replaced sent txs (`doesExist == false` and listed in another tx's `boostTxIds`) are hidden (`filterOutReplacedSentTransactions`).
- Rows (`ActivityRow`): Lightning shows pending/failed/sent/received; on-chain shows transferring, boost fee (CPFP child), boosting, removed, confirms-in text. A contact (only when Paykit UI is active) replaces the icon with an avatar and the title with "sent to/received from <name>" (not for transfers, unconfirmed boosts, non-succeeded Lightning).
- Icons (`ActivityIcon`): purple for Lightning; orange for on-chain; transfers use arrow-up-down (orange sent, purple received); boosted unconfirmed and CPFP child use a clock icon, id `BoostingIcon`; removed uses a red x; hardware wallets draw blue.
- Detail (`ActivityItemView`): status, date, time, amount, fee, contact, tags, invoice note, buttons Tag, Assign/Detach, Boost, Explore, Connection (transfers only). Title becomes the transfer title for `isTransfer`.
- Explorer (`ActivityExplorerView`): on-chain TXID, inputs/outputs from Electrum, boost tx ids; Lightning preimage, payment hash, invoice; button opens `Env.blockExplorerUrl/tx/<txid>` (on-chain only). Tapping an info block copies it.
- Boost (`BoostSheet`): received unconfirmed tx gets CPFP, sent unconfirmed tx gets RBF. Rates: CPFP min 10, max 1000, default `max(1.5 x fast, 20)`; RBF min `max(original + 2, 2)`, max 500, default `max(fast, min)`; size fixed at 250 vB (code `TODO`). Swipe calls `ActivityListViewModel.boost`, then syncs wallet and activity.
- Boost button is disabled for hardware activity, CPFP child, `doesExist == false`, confirmed, Lightning, sent and already boosted, received with an existing boost tx.
- Tags: add on detail via `AddTagSheet` (recent tags in `TagManager.lastUsedTags`, max 10); remove with the chip's x; filter via `TagFilterSheet`. Tag list management is in Settings > General (`TagsSettings`, row only when recent tags exist).

## How a user reaches it
- Home list: `ActivityShort-<index>` (no date headers), `ActivityShowAll`. Drawer: `HeaderMenu` then `DrawerActivity` (`DrawerView`). Savings/Spending/hardware screens have rows `Activity-<index>`; Savings and Spending add a "Show all" button without an identifier. All use route `.activityList` / `.activityDetail`.
- All Activity: tabs `Tab-all`, `Tab-sent`, `Tab-received`, `Tab-other` (`SegmentedControl` id `Tab-<title lowercased>`, English only), rows `Activity-<index>`, filter icons `TagsPrompt` and `DatePicker` (both `.onTapGesture` images). The search field has no identifier.
- Index note: `Activity-<index>` counts date headers (`zip(groupedItems.indices, groupedItems)` in `ActivityList.swift`), so the first row is usually `Activity-1`.
- Tag filter: `TagsPrompt` opens `TagFilterSheet`; chips `Tag-<tag>`; tapping selects and closes; the selected pill's remove is `Tag-<tag>-delete`.
- Date filter: `DatePicker` opens `DateRangeSelectorSheet`: `PrevMonth`, `NextMonth`, `Day-<n>`, `Today`, `CalendarClearButton`, `CalendarApplyButton`.
- Detail ids: `ActivityAmount`, `ActivityFee`, `ActivityTags` (only when a tag exists), `InvoiceNote`, `ActivityTag`, `ActivityAssignContact` or `ActivityDetachContact` (Paykit UI active only), `BoostButton` | `BoostedButton` | `BoostDisabled`, `ActivityTxDetails`, `ChannelButton`; status `StatusConfirmed` | `StatusConfirming` | `StatusBoosting` | `StatusRemoved` (on-chain only). Other entries to detail: Send success and pending screens, contact activity.
- Add tag sheet: `TagInput`, `ActivityTagsSubmit`. Boost sheet: container `CPFPBoost` or `RBFBoost`, `CustomFeeButton`, `Plus`, `Minus`, `RecommendedFeeButton`, swipe `GRAB`; toasts `BoostSuccessToast`, `BoostFailureToast`.
- Assign contact: `ActivityAssignContact` opens `AssignActivityContactView` (rows `AssignContact-<publicKey>`); a tap assigns and goes back.
- Explorer ids: `TXID`, `RBFBoosted` or `CPFPBoosted` (boost tx rows).
- Channel details from activity: `ChannelButton` on a transfer opens `connectionDetail(channelId:)` (`LightningConnectionDetailView`, see `settings.md`).

## Code
- Views `Bitkit/Views/Wallets/Activity/`: `AllActivityView`, `ActivityItemView`, `ActivityExplorerView`, `ActivityRow`, `ActivityRowLightning`, `ActivityRowOnchain`, `ActivityIcon`, `ActivityLatest`, `AssignActivityContactView`. `Bitkit/Components/Activity/`: `ActivityList`, `ActivityListFilter`, `ActivityBanner`, `DateRangeSelectorSheet`, `TagFilterSheet`. Sheets `Bitkit/Views/Wallets/Sheets/BoostSheet.swift`, `AddTagSheet.swift`. Tags `Bitkit/Components/Tags/`, `Bitkit/Managers/TagManager.swift`, `Bitkit/Views/Settings/General/TagSettingsView.swift`.
- Routes (`NavigationViewModel.Route`): `activityList`, `activityDetail(Activity)`, `activityExplorer(Activity)`, `assignActivityContact(activityId:walletId:)`, `tagSettings`. Sheets (`SheetID`): `boost`, `addTag`, `tagFilter`, `dateRangeSelector`; the filter views present the last two with a plain SwiftUI `.sheet`.
- State: `Bitkit/ViewModels/ActivityListViewModel.swift` (filters, `groupActivities`, `boost`, `syncLdkNodePayments`), `ActivityItemViewModel.swift` (tags, RBF replacement lookup, 3 tries), data in `ActivityService` (`Bitkit/Services/CoreService.swift`: `get`, `boostOnchainTransaction`, `isCpfpChildTransaction`, `getBoostTxDoesExist`). `Bitkit/Extensions/Activity+Contact.swift` (`isHardwareWallet`, `contact(in:)`). Constants `Bitkit/Models/ActivityDisplayConstants.swift`.

## How to drive it
- Journeys: there is no activity folder under `journeys/`. Activity appears in `journeys/hardware-wallet/activity-blue-icons.xml` ("Hardware Wallet Activity Blue Icons") and `activity-detail-hw-tags.xml` ("Hardware Wallet Activity Tags And Inputs Outputs"), see `hardware-wallet.md`; `journeys/pubky-marketplace/wallet-leg.xml` also names activity ids.
- E2E `bitkit-e2e-tests/test/specs/boost.e2e.ts`, describe `@boost @ios_gate`: `@boost_1` CPFP, `@boost_2` RBF. Filters: `onchain.e2e.ts` `@onchain_2 @ios_nightly` (tabs, `Tag-stag`, date range), `lightning.e2e.ts` `@lightning_1` (`@ios_gate`: tabs, `Tag-rtag`/`Tag-stag`). Tag add on detail: `backup.e2e.ts` `@backup_1` (`@ios_nightly`). `multiaddress.e2e.ts` `@multi_address_3` (`@ios_gate`) reads `ActivityTxDetails`. `settings.e2e.ts` `@settings_04` (`@ios_nightly`) removes a Receive-created tag in `TagsSettings`; it does not touch activity tags.
- Preconditions: `BACKEND=local` docker (bitcoind, Electrum), `ensureLocalFunds`, `initElectrum`. `@boost_1` calls `receiveOnchainFunds({ sats: 100_000, blocksToMine: 0 })` so the tx stays unconfirmed; `@boost_2` sends to `getExternalAddress()`. Boost needs an exclusive miner (e2e `AGENTS.md`: Mini runs it).
- Unit tests: `BitkitTests/ActivityListTest.swift` (tags, contact, boost cache, hardware snapshot), `ActivityHardwareTests.swift`, `HwActivityTagBackupTests.swift`, `MarkAllUnseenActivitiesCutoffTests.swift`, `RestoreActivitySeenSuppressionTests.swift`.

## What proves it
- CPFP: toast `BoostSuccessToast`; `BoostingIcon`; `ActivityShort-0` shows "Boost Fee" and "-", `ActivityShort-1` keeps "100 000" and "+"; original detail shows `BoostedButton` and `StatusBoosting`; explorer `CPFPBoosted` equals the new tx's `TXID`; after a block `StatusConfirmed`. State survives wipe and restore.
- RBF: sheet `RBFBoost`; new `ActivityFee` greater than old, `TXID` differs, explorer `RBFBoosted`; confirmed receive row shows `BoostDisabled`.
- Filters: per-tab presence/absence of `Activity-1..n`; `Tag-stag` leaves one row; next-month range leaves none; `CalendarClearButton` and `Today` restore all rows.
- Tag add: chip visible in `ActivityTags` (`@backup_1` restores and checks later); `Tag-<tag>-delete` visible on a hardware send detail (`expectHardwareWalletSentActivity`).

## Not covered by tests
- Search text filter, date range with one boundary, combined filters: no test found.
- Assign/detach contact (`ActivityAssignContact`, `AssignContact-*`): no journey or e2e found; unit tests cover `setContact` in `ActivityListTest.swift`.
- `BoostFailureToast`, fee below minimum (`wallet__min_possible_fee_rate_msg`), `Plus`/`Minus` bounds: not asserted (`Plus`/`Minus` are only tapped).
- `StatusRemoved`, RBF replacement lookup in `ActivityItemViewModel`, Lightning detail `.pending` and `.failed`: none found.
- `ActivityBanner` text, explorer "open in block explorer" button, `ChannelButton` navigation: none found.
- Boost button on iOS for hardware activity (always disabled): no test found.

## Gotchas
- `TagsPrompt` and `DatePicker` are tap-gesture images, not buttons; `snapshot-ui` may omit them (`journeys/README.md`), check with `wait-for-ui --identifier`.
- `Tab-*` ids derive from the localized tab title; English only.
- The receive-tag filter is commented out in `@onchain_2` (TODO, bitkit-android issue 322); only the send-tag filter runs there.
- Activity ids are unique per wallet only; routes and sheets carry `walletId` (`AddTagConfig`, `assignActivityContact`).
- `ActivityTags` renders only after a tag exists; the filter chip list is `TagsPrompt`, not `ActivityTags`.
- Assign/Detach buttons are hidden unless `PaykitFeatureFlags.isUIAvailable` and the Paykit UI toggle are on.
- Hardware row indices: `Activity-<n>` on the hardware screen and All Activity use the same header-counting scheme; the home list `ActivityShort-<n>` does not.
