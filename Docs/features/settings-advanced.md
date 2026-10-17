# Settings: Advanced tab and node/debug tools

Scope: Settings -> Advanced tab (address types, coin selection, address viewer, watch-only accounts, lightning connections and node info, Electrum, RGS) and the Dev Settings tools LDK Debug, VSS Debug, Probing Tool. General tab and Dev Settings list: `settings.md`. Opening/closing channels: `transfer.md`.

## What it does
- Address type (`AddressTypePreferenceView`): choose primary receive type `legacy` (p2pkh), `nestedSegwit` (p2sh-p2wpkh), `nativeSegwit` (p2wpkh, default), `taproot` (p2tr). `SettingsViewModel.updateAddressType` sets the node primary type, restores the previous address on failure, then syncs. With `showDevSettings` on, a "monitored address types" list adds toggles; native segwit cannot be unmonitored (refund monitoring) and the selected type cannot be unmonitored.
- Coin selection (`CoinSelectionSettingsView`): method `manual` or `autopilot`; autopilot shows algorithm choice (`branchAndBound`, `largestFirst`, `oldestFirst`, `singleRandomDraw`; `smallestFirst`/`consolidate` are commented out as unsupported).
- Address viewer (`AddressViewer`): lists receiving or change addresses per script type, 20 at a time with load more, search, per-address balance, QR for the selected address.
- Watch-only accounts (`WatchOnlyAccountsView`): active accounts with tracking toggle, rename, copy xpub; pending accounts listed separately. Accounts are created by the Pubky auth watch-only claim (`PubkyService.swift` takes a `WatchOnlyAccountManager`; entry link `bitkit://pubky-auth/setup`, see `deeplinks.md`, `profile-pubky.md`); the manager is also restored from backup and cleared on wallet reset.
- Lightning connections (`LightningConnectionsView`): spending balance and receiving capacity header, pending/open/closed lists, "show closed" toggle, plus button to funding options; detail screen (`LightningConnectionDetailView`) shows size, usable flag, and a close action (`CloseConnectionConfirmation`).
- Lightning node (`NodeStateView`): node state and node id.
- Electrum (`ElectrumSettingsScreen`): host, port, TCP/TLS radio, connect, reset to default, scan QR. Scan formats parsed by `SettingsViewModel.onElectrumScan` (handled via `ScannerManager.handleElectrumScan`, scanner context `.electrum`).
- RGS (`RgsSettingsScreen`): server URL field validated by `SettingsViewModel.isValidRgsUrl`, connect, reset.
- LDK Debug (`LdkDebugScreen`): add peer (typed or pasted node URI), log/delete network graph, restart node, peer simulation. VSS Debug (`DevSettings/VssDebugScreen.swift`): tabs App and LDK, list/export/delete VSS keys, delete all app keys. Probing Tool (`ProbingToolScreen`): probe a BOLT11 invoice or node id with an amount, shows route result and duration (`LightningService.sendProbe`, `sendProbesSpontaneous`).

## How a user reaches it
- `HeaderMenu` -> `DrawerSettings` -> `Tab-advanced`. Rows (NavigationLink ids): `DevSettings` (only if `showDevSettings`), `AddressTypePreference`, `CoinSelectPreference`, `AddressViewer`, `WatchOnlyAccounts` (only with Paykit UI available and enabled), `Channels`, `LightningNodeInfo`, `ElectrumConfig`, `RGSServer`.
- Address type options: ids `p2pkh`, `p2sh-p2wpkh`, `p2wpkh`, `p2tr`; monitor toggles `MonitorToggle-<id>`; toasts `AddressTypeApplyingToast`, `AddressTypeSettingsUpdatedToast`. Coin selection options have no ids.
- Address viewer: tabs `Tab-receiving addresses` / `Tab-change addresses` (derived from title), script type chips by text (`Legacy`, `Taproot`, ...), rows `Address-<index>`. e2e taps by text.
- Watch-only: `WatchOnlyAccountsEmpty`, `WatchOnlyAccount_<n>`, `WatchOnlyAccountTracking_<n>`, `WatchOnlyAccountName_<n>`, `WatchOnlyAccountSaveName_<n>`, `WatchOnlyAccountXpub_<n>`, `WatchOnlyAccountCopyXpub_<n>`, `WatchOnlyAccountPending_<n>`.
- Connections: `NavigationAction` (plus -> `fundingOptions`), rows `Channel` (same id on every row), detail ids `TotalSize`, `IsUsableYes`/`IsUsableNo`, `CloseConnection`, then `CloseConnectionButton`. Node: `LDKNodeID`.
- Electrum: `NavigationAction` (scanner), `ElectrumStatus`, `Connected`/`Disconnected`, `HostInput`, `PortInput`, `ResetToDefault`, `ConnectToHost`; toasts `ElectrumUpdatedToast`, `ElectrumErrorToast`. RGS: `ConnectedUrl`, `RGSUrl`, `ResetToDefault`, `ConnectToHost`; toasts `RgsUpdatedToast`, `RgsErrorToast`.
- Dev tools: Advanced -> `DevSettings` -> rows LDK / VSS / Probing Tool (rows have no ids; Probing Tool scan button `ProbingToolScan`).

## Code
- `Bitkit/Views/Settings/Advanced/` (all screens above), `Bitkit/Views/Settings/LdkDebugScreen.swift`, `DevSettings/VssDebugScreen.swift`, `ProbingTool/*`, `Bitkit/Components/NodeStateView.swift`.
- Routes: `.addressTypePreference`, `.coinSelection`, `.addressViewer`, `.watchOnlyAccounts`, `.connections`, `.connectionDetail(channelId:)`, `.closeConnection(channel:)`, `.node`, `.electrumSettings`, `.rgsSettings`, `.devSettings`, `.ldkDebug`, `.vssDebug`, `.probingTool`, `.scanner`, `.fundingOptions` (`Bitkit/ViewModels/NavigationViewModel.swift`, destinations in `Bitkit/MainNavView.swift`). No sheets.
- State/services: `Bitkit/ViewModels/SettingsViewModel.swift` (`selectedAddressType`, `addressTypesToMonitor`, `coinSelectionMethod/Algorithm`, electrum*/rgs* fields), `Bitkit/Extensions/LDKNode+AddressType.swift` (`testId`), `Bitkit/Services/ElectrumConfigService.swift`, `RgsConfigService.swift`, `WatchOnlyAccountService.swift`, `LightningService.swift`, `VssBackupClient.swift`, `Bitkit/ViewModels/ChannelDetailsViewModel.swift`.

## How to drive it
- e2e `bitkit-e2e-tests/test/specs/settings.e2e.ts` (describe `@settings @ios_nightly`): `@settings_08` address types (`ciIt.skip`), `@settings_09` `LightningNodeInfo` -> `LDKNodeID`, `@settings_10` Electrum wrong server + scan formats (returns early unless `BACKEND=local`), `@settings_11` RGS change and reset.
- e2e `bitkit-e2e-tests/test/specs/multiaddress.e2e.ts` (describe `@multi_address`; `@multi_address_1` is `@ios_nightly`, `@multi_address_3` and `@multi_address_4` are `@ios_gate`, `@multi_address_2` has `@multi_address_staging @staging`). Preconditions: `ensureLocalFunds`, `initElectrum`, bitcoin RPC (regtest docker), `@multi_address_4` also local LND (`setupLND`, `lndConfig`). Uses `switchAndFundEachAddressType` (`test/helpers/actions.ts`): `openSettings('advanced')` -> `AddressTypePreference` -> type id -> deposit -> mine.
- Other specs that use Advanced rows: `lightning.e2e.ts` (`Channels`, `Channel`, `CloseConnection`; describe `@lightning @ios_gate`), `transfer.e2e.ts` (`Channels`, `Channel`), `onboarding.e2e.ts` (`AddressViewer` after restore, `@onboarding_2`), `test/helpers/lnd.ts` (`LightningNodeInfo`, `Channels`, `NavigationAction`, `FundManual`).
- e2e `bitkit-e2e-tests/test/specs/mainnet/probe.e2e.ts` (`@probe_mainnet`, `@probe_mainnet_1`): does not touch the in-app Probing Tool; its helpers (`test/helpers/probe.ts`) call `adb shell content ... .devtools`, so it is Android-only. Docs: `bitkit-e2e-tests/docs/mainnet-probe.md`. Needs `PROBE_SEED`, `PROBE_TARGETS_JSON`, `BACKEND=mainnet`.
- Journeys: none for Advanced settings. Related: `journeys/pubky-auth/open-watch-only-link.xml` ("open watch-only auth link") creates the consent that precedes a watch-only account.
- Unit tests: `BitkitTests/AddressTypeSettingsTests.swift`, `AddressTypeAccountTests.swift`, `AddressTypeDerivationTests.swift`, `AddressTypeIntegrationTests.swift`, `UtxoSelectionTests.swift`, `SettingsUrlValidationTests.swift`, `AddressSearchCoordinatorTests.swift`, `WatchOnlyAccountServiceTests.swift`.

## What proves it
- Address type: receive address prefix (`assertAddressMatchesType`: `m`/`n`, `2`, `bcrt1q`, `bcrt1p`), total balance after each deposit, Address Viewer text shows `formatSats(balance)` under the type tab.
- Electrum: toast `ElectrumErrorToast` for a bad server, `ElectrumUpdatedToast` then `Connected` after reset; `HostInput`/`PortInput` text matches parsed scan. RGS: `ConnectedUrl` text equals the new URL, then the original after reset, with `RgsUpdatedToast`.
- Node info: `LDKNodeID` displayed. Channels: `TotalSize` text `₿ <size>`, `IsUsableYes`; after close `Channel` disappears and text `Transfer Initiated` appears.

## Not covered by tests
- No e2e/journey for: coin selection screen, watch-only accounts screen (only unit tests of the service), closed-connections list, pending connections, address viewer search / load more / change tab beyond `Change Addresses` text, monitor-address-type toggles, LDK Debug, VSS Debug, in-app Probing Tool, Electrum TLS success against a real TLS server, RGS invalid URL.
- Address type switch failure path (error toast, rollback) has no UI test; `SettingsViewModel` rollback is only indirectly unit-tested (could not confirm which test).

## Gotchas
- `@settings_08` is `ciIt.skip` with the comment "not available in ldk-node", yet address type switching works and `multiaddress.e2e.ts` relies on it; the skip comment looks stale (unverified why it is still skipped).
- `@settings_10`: the `:s` and `https://` formats expect `ElectrumErrorToast` and the `:t`/`http://` formats `ElectrumUpdatedToast` (the spec gives no reason; the local server URL is `tcp://`); the protocol assertion (`ElectrumProtocol`) is commented out in the spec.
- `PortInput`/`HostInput` ids are shared by Electrum settings and the manual-channel funding screen (`FundManual`); `ResetToDefault`/`ConnectToHost` are shared by Electrum and RGS.
- `Channel` id is on every row, so use `elementsById`.
- In an `E2E_BUILD`, the default Electrum URL is `tcp://127.0.0.1:60001` (`Env.electrumServerUrl`), and the default shown in `ElectrumConfig` row is "Auto" only while the current server equals that default.
- Watch-only row is hidden unless Paykit UI is on (dev setting `PaykitUiToggle`).
