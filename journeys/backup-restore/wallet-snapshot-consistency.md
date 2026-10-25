# Wallet snapshot consistency

Use an isolated test wallet and backup destination. Controlled SDK/capture/upload
gates and inspection of stored backup envelopes are not journey Capabilities;
these checks require a dedicated fault-injection fixture. Do not inject into a
funded personal wallet or shorten payment safety waits.

1. Queue a wallet backup behind a Paykit mutation, then release the mutation.
   Verify the exported SDK state includes it and a consistent snapshot uploads.
2. Hold snapshot capture after the SDK export, change private payment state, and
   release capture. Verify the discarded snapshot never uploads and a fresh,
   consistent capture succeeds when activity settles.
3. Keep changing state through each capture attempt. Verify no mixed snapshot
   uploads, the wallet remains pending backup, and automatic backup succeeds
   after the fixture becomes quiet without requiring another state change.
4. Change state during a held upload. Verify completion does not mark the newer
   state backed up, and the subsequent upload contains that state.
5. Cancel capture or replace the identity while capture/retry is held. Verify no
   mixed-identity snapshot uploads. Verify SDK/export/upload failures and unsigned
   payment attempts still fail without being reported as successful backups.
6. Restore a successful captured envelope into an isolated fixture. Verify its
   SDK state, private consumption state, reservations, proofs and signed active
   payment attempt agree. Do not broadcast a payment as part of this check.

On iOS, place fixture gates at `BackupService` wallet capture/upload and
`PaykitSdkService` export. Include the `WalletBackupRestoreGate` pending-restore
check and `PaykitPaymentProofService` active-attempt guard. Use a dedicated
simulator through XcodeBuildMCP; do not reset or reuse another test's simulator.
Also repeat the held-upload check for settings, widgets, activity, metadata and
Blocktank backups, including a scheduled backup overlapping a manual upload.
Each category must upload its pending changes after release without another
mutation. A genuine capture/upload failure must not enter an automatic retry loop.

Record the tested commit, gate locations, attempts and upload counts, and the
restored state. Unit coverage does not establish a device pass or a maximum
backup delay during sustained activity.

## Backup observation shutdown

The following controls require the same dedicated lifecycle/capture fixture;
these are not ordinary UI journey capabilities. No wallet reset is needed.

1. Hold a scheduled backup in its cancellable debounce, stop observation, and
   request a manual metadata backup while cancellation cleanup remains held.
   Verify shutdown and the manual upload both wait for cleanup, including a final
   status write held after the delay finishes. Release cleanup;
   verify pending wallet work remains required and resumes on observation restart.
   Change wallet/settings state after requesting restart while cleanup is held;
   verify no new upload starts before the drain and the latest state uploads
   afterward without another edit. Repeat with a canceled settings upload; its
   cleanup must not clear a newer required marker.
2. Request a new USDT recovery backup during cleanup and again after observation
   is stopped. Verify both requests can finish without restarting Lightning, and
   transient backup failures retain bounded automatic retry.
3. Repeatedly start and immediately stop observation. Change a wallet record only
   after stop returns; verify the stopped observer does not schedule an upload or
   mutate its saved backup status. Restart observation and verify a single set of
   listeners resumes pending work. Also receive a settings-change notification
   immediately before stop: its pending marker must survive the stopped listener.

The iOS lifecycle unit tests exercise these component boundaries with injected
capture/upload and delay controls. They do not prove a full device fault journey.
Android's related job-ownership and reset paths require separate validation.
