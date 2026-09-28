# Onchain receive journeys

These journeys cover the received sheet for onchain deposits (issue #455, Android #797). Ported from
`bitkit-android/journeys/onchain-receive` with synonymdev/bitkit-ios#588.

ldk-node emits `onchainTransactionReceived` when the wallet sync finds a transaction in the mempool
and `onchainTransactionConfirmed` when it confirms. A transaction that is mined before any sync sees
it in the mempool produces only the confirmed event. `AppViewModel.handleLdkNodeEvent` routes both to
`presentReceivedSheetForOnchainTransaction`, which reserves the txid in-session and checks the
persisted seen state, so a tx shows one sheet whichever event reaches it first.

A confirmed-only receive is shown only when its block timestamp is within one hour of the device
clock and no migration is running (`AppViewModel.shouldPresentConfirmedOnlyReceive`, matching
Android's `MAX_CONFIRMED_ONLY_AGE`). A full wallet scan replays old confirmations, which the window
keeps silent. After a seed restore, `RestoreWalletView` sets `pendingRestoreActivitySeenSince` before
the node starts, which holds every onchain received sheet until the first onchain sync completes;
that sync marks the activities that existed before the restore began as seen and clears the flag, so
the transactions it discovered stay silent when they later confirm while new deposits notify again.
That sync also records its chain tip in `restoreSyncedBlockHeight`, and confirmed-only receives at or
below it stay silent, so a replayed or late-handled confirmation of a pre-restore tx never shows a
sheet (Android #1342). The restore journey needs a throwaway simulator, since it uninstalls the app
and restores a public test seed; the rest is covered by `ConfirmedOnlyReceiveGuardTests`,
`RestoreActivitySeenSuppressionTests` and `MarkAllUnseenActivitiesCutoffTests`.

## Adapted from Android

- `confirmed-only-background-notification.xml` is not ported. It covers Android's
  `LightningNodeService` foreground service, which posts a "Payment Received" notification while the
  app is in the background. iOS has no foreground node service and the notification extension only
  handles Blocktank pushes, so there is no iOS path to drive.
- `mempool-then-confirmed-single-sheet.xml` drops the final "no Payment Received notification" check
  for the same reason.
- Android skips confirmed-only receives while a backup restore runs; iOS relies on the restore hold
  above, which covers the same window.

## Preconditions

- Onboarded regtest wallet with the node running, built with `E2E_BUILD` against the local
  `bitkit-docker` stack (see the suite-wide [README](../README.md#backend-preconditions)). Fund and
  mine with the `lsp` helper from the sibling Android checkout.
- Wallet sync runs every 10s. For the confirmed-only journey, run the deposit and the mine in one
  shell command, then check the log: an `Onchain transaction received` line for the txid means the
  sync saw the mempool first and the run tested the other path.
- The app writes its log to the app group, not `os_log`: `logs/bitkit_*.log` under
  `xcrun simctl get_app_container booted to.bitkit group.bitkit`. `LightningService` logs each onchain
  event as `📥 Onchain transaction received: txid=…` or `✅ Onchain transaction confirmed: txid=…`.
