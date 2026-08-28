# Hardware wallet journeys

Cover pairing a Trezor, the home tile and detail screen, the Hardware Wallets settings surface,
passphrase (hidden) wallets, wallet-scoped activity, and the watch-only Transfer To Spending flow.

## Transport: Bridge, not USB

iOS cannot do WebUSB, and `Docs/AI_DEVICE_TESTS.md` explains the consequence: the Trezor User Env
emulator is reached through **Trezor Bridge on the host**, and the simulator talks to that localhost
endpoint. `Bitkit/Services/Trezor/` carries both `TrezorBridgeTransport` and `TrezorBLEManager`;
these journeys drive the Bridge path.

`usb-reconnect.xml` therefore has no iOS counterpart and is replaced by `reconnect.xml`, which
exercises the same disconnect-indicator and reconnect chain through the dev Trezor screen instead of
an injected `USB_DEVICE_ATTACHED` intent.

## Setup

Start the emulator stack from a sibling `bitkit-docker` checkout on `main`:

```bash
cd /path/to/bitkit-docker
docker compose up -d
./scripts/trezor-emulator start
```

For the passphrase journeys, start it with passphrase protection instead:

```bash
TREZOR_PASSPHRASE_PROTECTION=true ./scripts/trezor-emulator start
```

Then build and run with the Bridge environment (mirrors the `xcodebuild` invocation in
`Docs/AI_DEVICE_TESTS.md`):

```bash
TEST_TREZOR_EMU=1 TREZOR_BRIDGE=true TREZOR_BRIDGE_URL=http://127.0.0.1:21325 \
xcodebuildmcp simulator build-and-run \
  --extra-args "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) E2E_BUILD TEST_TREZOR_EMU"
```

## Order

Several journeys mutate pairing state. Run them in this order, or re-pair between runs:

1. `connect-home-tile.xml` — pairs the emulator; every other journey assumes it ran.
2. `settings-hardware-wallets.xml`, `connect-flow.xml`, `suggestion-intro-sheet.xml` — each forgets
   and re-pairs the device, ending paired.
3. `activity-blue-icons.xml`, `activity-detail-hw-tags.xml`, `transfer-to-spending*.xml`, `reconnect.xml`.
4. `passphrase-pairing.xml` → `passphrase-duplicate.xml` → `passphrase-transfer-to-spending.xml` →
   `passphrase-settings-remove.xml`.
5. `detail-overview.xml` **last** — its final step forgets the device.

## Approving prompts on the emulator

The device blocks until each prompt is acknowledged, once per address type for a passphrase session:

```bash
../bitkit-docker/scripts/trezor-emulator send-json '{"type":"emulator-press-yes","id":1}'
```

## Checking for passphrase leaks

Unlike the notification extension, the app writes its logs as **files in the app group container**,
not to `os_log`. Resolve the container and grep it:

```bash
GROUP=$(xcrun simctl get_app_container "$UDID" to.bitkit groups | awk '{print $2}')
[ -d "$GROUP" ] || { echo "LEAK_CHECK_INVALID: container not found"; exit 1; }
grep -rl "bitkit-hidden" "$GROUP"; s=$?
case $s in 1) echo NO_PASSPHRASE_LEAK;; 0) echo "LEAK FOUND";; *) echo "LEAK_CHECK_INVALID: grep exit $s";; esac
```

`grep ... || echo NO_PASSPHRASE_LEAK` — the form the Android journeys use — prints the clean result
for *every* nonzero status, so a missing container or an unresolved simulator passes the security
check without scanning anything. Only exit status 1 means "no match"; resolve `$UDID` explicitly
rather than relying on `booted`.

## Verified on simulator

Walked as far as a simulator allows, against a wallet with two Trezor identities already paired:

- **The simulator has no Bluetooth LE.** Tapping Continue on the connect intro raises a
  "Bluetooth Unsupported — This device does not support Bluetooth Low Energy" dialog and the flow
  never reaches the Searching step. Every journey that pairs, re-pairs or reconnects therefore needs
  the Bridge build above (`TREZOR_BRIDGE=true`) or a physical device. The read-only journeys —
  detail overview, activity, settings listing — run fine on a plain simulator build.
- **iOS settings has no "Payments" section.** The Hardware Wallets row sits in a flat list under the
  General tab (id `Tab-general`); the Android journeys' "scroll to Payments" step has been rewritten
  to scroll to the row itself.
- **The intro headline renders uppercase** ("ADD YOUR HARDWARE WALLET"), unlike Android's sentence
  case, so assert accordingly or match case-insensitively.
- Row identifiers are inconsistent in the app and this is not a typo in the journeys:
  `HardwareWalletRowName<id>` has **no** separator, while `HardwareWalletRowDelete_<id>` and
  `HardwareWalletRow_<id>` use an underscore. The `<id>` is the full `trezor:<hex>` device id.
- Confirmed resolving without the emulator: `HardwareWalletsSettings`, `HardwareWalletsScreen`,
  `AddHardwareWallet`, `HardwareWalletIntroScreen`/`Continue`/`Cancel`, `HardwareWalletScreen`,
  `HardwareTransferToSpending`, `HardwareTransferAmount` and its Available/25%/MAX/Continue controls,
  and the number pad keys.

## Identifiers used
- Dev Trezor screen: `TrezorScanButton`, `TrezorDevice-bridge`, `TrezorKnownDeviceConnect-bridge`,
  `TrezorForgetDevice-bridge`, `TrezorDisconnectButton`, `TrezorSection-DeviceInfo`.
- Connect sheet: `HardwareWalletIntroScreen`/`HardwareWalletIntroContinue`/`HardwareWalletIntroCancel`,
  `HardwareWalletSearchingScreen`/`HardwareWalletSearchingCancel`,
  `HardwareWalletFoundScreen`/`HardwareWalletFoundConnect`/`HardwareWalletFoundCancel`,
  `HardwareWalletPairedScreen`/`HardwareWalletPairedFinish`/`HardwareWalletPairedPassphrase`,
  `HardwareWalletLabelInput`, `HardwareWalletPairCodeScreen`.
- Passphrase: `HardwareWalletPassphraseScreen`/`HardwareWalletPassphraseInput`/
  `HardwareWalletPassphraseContinue`/`HardwareWalletPassphraseBack`,
  `HardwareWalletPassphrasePairedScreen`, `HwPassphraseError`.
- Settings: `HardwareWalletsSettings`, `HardwareWalletsScreen`, `AddHardwareWallet`,
  `HardwareWalletRow_<id>`, `HardwareWalletRowName<id>`, `HardwareWalletRowDelete_<id>`,
  `RenameHardwareWalletInput`, `RenameHardwareWalletSave`.
- Home and detail: tile `ActivityHardware`, screen `HardwareWalletScreen`, `RemoveHardwareWallet`,
  `RemoveHwWalletDialog`, `HwRemoveKeepBackupToggle`.
- Transfer: `HardwareTransferToSpending`, `HardwareTransferAmount`,
  `HardwareTransferAmountAvailable`/`Quarter`/`Max`/`Continue`, `HardwareTransferSign`,
  `HardwareTransferSignLearnMore`/`SignAdvanced`/`SignDefault`,
  `HardwareTransferOpenTrezorConnect`, `HardwareTransferSigned`,
  `HwTransferPassphraseSheet`/`Input`/`Continue`/`Cancel`.
- Activity: `ActivityShowAll` (home only). Rows use **two different schemes** — `ActivityShort-<index>`
  in the home recent list, `Activity-<index>` in All Activity and on the hardware wallet screen.
  Tabs `Tab-all`/`Tab-sent`/`Tab-received`/`Tab-other`,
  Tag button `ActivityTag` (labelled "Tag"), tag field `TagInput`, submit `ActivityTagsSubmit`,
  detail chip list `ActivityTags` (only rendered once a tag exists), All Activity tag filter
  `TagsPrompt` (not `ActivityTags` — that one is detail-screen only), explorer `ActivityTxDetails`.
