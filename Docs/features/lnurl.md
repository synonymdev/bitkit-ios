# LNURL

LNURL-pay (and Lightning Addresses), LNURL-withdraw (receive over lightning), LNURL-channel and LNURL-auth. All four enter through the scanner/paste/manual-entry path described in `send.md`. Split out of `send.md`/`receive.md` because of size; `receive.md` points here for withdraw.

## What it does
- `AppViewModel.handleScannedData` decodes the input with `decode(invoice:)` (BitkitCore, not read) into `.lnurlPay`, `.lnurlWithdraw`, `.lnurlChannel`, `.lnurlAuth` and dispatches (`handleScannedData` switch, then `handleLnurlPayInvoice`, `handleLnurlWithdraw`, `handleLnurlChannel`, `handleLnurlAuth`).
- Pay: refused with a toast if the node is not running or Lightning balance is below `max(1, minSendableSat)` (`LnurlPayNoCapacityToast`, title "Unable To Pay (LNURL)"). Otherwise sets `app.lnurlPayData`. Fixed amount (min == max, or sub-sat rounding inversion) goes to `lnurlPayConfirm`; variable goes to `lnurlPayAmount` (amount capped at `min(maxSendableSat, spending balance)`, min enforced on Continue with `LnurlPayAmountTooLowToast`). Quickpay can replace the confirm screen (see `send.md`). Confirm fetches the bolt11 callback with the exact msat amount (fixed amounts are sent verbatim, `callbackAmountMsats` in `Bitkit/Extensions/LnurlPayData+Amount.swift`), optional comment up to `commentAllowed`, then pays like a normal lightning invoice.
- Withdraw: needs the node running and Lightning balance >= `max(1, minWithdrawableSat)` (else warning toast `other__lnurl_withdr_error*`, no id); min > max is also refused. Sets `app.lnurlWithdrawData`. Fixed amount opens the confirm screen, variable opens the amount screen. Confirm creates an invoice (`wallet.createInvoice`/`createInvoiceMsats`, expiry 3600 s, memo = `defaultDescription`) and calls the withdraw callback (`LnurlHelper.handleLnurlWithdraw`). Success: info toast and sheet closes; the paid invoice then raises the normal received sheet. Failure: `LnurlWithdrawFailure` (hard-coded English strings, TODO in code).
- Channel: needs node running; hides the sheet and navigates to `Route.lnurlChannel`. Connect first calls `wallet.connectPeer`, then the channel callback with `isPrivate: true`, then navigates to `.fundManualSuccess`.
- Auth: needs node running; opens the `lnurlAuth` sheet. Continue signs with the wallet mnemonic (`lnurlAuth(...)` from BitkitCore), shows a success toast and closes. Labels depend on `authData.tag`: `login`, `register`, `link`, else "Authenticate".

## How a user reaches it
- Scan: tab bar `Scan` opens `SheetID.scanner` (`ScannerSheet`); paste button; or from Send: `Send` -> `RecipientInvoice` (clipboard) / `RecipientManual` -> `RecipientInput` -> `AddressContinue`.
- E2E builds only (`Env.isE2E`): `ScanPrompt` ("Enter QR Code String") on the scanner opens a dialog: `QRDialog`, `QRInput`, `DialogConfirm`, `DialogCancel` (`Views/Scanner/ManualScanPrompt.swift`).
- Pay screens: `SendNumberField`, `ContinueAmount`, `SendAmountExceededToast`, `LnurlPayAmountTooLowToast`, `LnurlPayAmountTooHighToast`, `CommentInput`, `ReviewAmount(-primary)`, swipe `GRAB`, then `SendSuccess`, `Close`.
- Withdraw screens: `SendNumberField`, `ContinueAmount`, `SendAmountExceededToast`, confirm `WithdrawAmount(-primary)`, `WithdrawConfirmButton`, received sheet `ReceivedTransaction`, `ReceivedTransactionButton`.
- Channel: `ConnectButton`, then `ExternalSuccess` and `ExternalSuccess-button`; toast `SpendingBalanceReadyToast` when the channel is ready.
- Auth: `LnurlAuth` (container), `LnurlAuthCancel`, `LnurlAuthContinue`.

## Code
- Pay: `Bitkit/Views/Wallets/Send/LnurlPayAmount.swift`, `LnurlPayConfirm.swift`; routes `SendRoute.lnurlPayAmount`/`.lnurlPayConfirm` in `SendSheet.swift`; `Bitkit/Utilities/Lnurl.swift` (`LnurlHelper.fetchLnurlInvoice`, `LnurlPayInvoiceMismatchError`); `Bitkit/Extensions/LnurlPayData+Amount.swift`.
- Withdraw: `Bitkit/Views/Wallets/LnurlWithdraw/` (`LnurlWithdrawSheet` with `LnurlWithdrawRoute` `.amount`/`.confirm`/`.failure`, `SheetID.lnurlWithdraw`, shown in `MainNavView.swift`). The same views are also mounted inside the Send sheet as `SendRoute.lnurlWithdrawAmount/Confirm/Failure`. Routing: `Bitkit/Utilities/PaymentNavigationHelper.swift` (`openPaymentSheet` for the scanner, `appropriateSendRoute` for the send sheet).
- Channel: `Bitkit/Views/Transfer/LnurlChannel.swift`, `Route.lnurlChannel(channelData:)` in `Bitkit/ViewModels/NavigationViewModel.swift`, rendered in `MainNavView.swift`, then `Views/Transfer/FundManualSuccessView.swift`.
- Auth: `Bitkit/Views/Sheets/LnurlAuth/LnurlAuthSheet.swift`, `SheetID.lnurlAuth`, `LnurlAuthConfig`.
- Scan entry: `Bitkit/Managers/ScannerManager.swift`, `AppViewModel.handleScannedData`, `handleLnurlPayInvoice`, `handleLnurlWithdraw`, `handleLnurlChannel`, `handleLnurlAuth`.

## How to drive it
- Journey `journeys/lnurl/pay-no-spending-balance.xml` ("lnurl pay without spending balance is refused"). Needs `bitkit-docker` `lnurl-server-fixture` (`docker compose --profile lnurl-pay up -d --build --wait lnurl-server-fixture`, port 3010, `GET /generate/pay`, `POST /fixture {"mode":"healthy"|"error"}`), `E2E_BUILD` app (plain HTTP allowed, default `E2E_BACKEND=local`, host `127.0.0.1` or `E2E_LOCAL_HOST`), wallet with no channels, link on the simulator clipboard (`xcrun simctl pbcopy`). `journeys/lnurl/README.md` has the setup.
- `journeys/payment-requests/definite-pre-broadcast-retry.xml` covers a failing then recovering invoice callback for a Payment Request (needs a Spending balance); see `payment-requests.md`.
- e2e `bitkit-e2e-tests/test/specs/lnurl.e2e.ts`: one test `@lnurl_1` under `@lnurl @ios_gate`. Needs `BACKEND=local`, docker bitcoind/electrum and LND (`lndConfig`), the `lnurl` npm server on `localhost:30001` backed by LND REST `127.0.0.1:8080`. Flow: fund 1000 sats, `setupLND`, lnurl-channel via `enterAddressViaScanPrompt`, lnurl-pay (min != max with comment, min == max, via manual entry), lnurl-withdraw (min != max, min == max), msat-precision pay and withdraw for 222538, 222222 and 500500 msats, lnurl-auth.
- e2e `bitkit-e2e-tests/test/specs/mainnet/ln.e2e.ts`: `@strike_mainnet`/`@strike_1` and `@wos_mainnet`/`@wos_1`, pays a Lightning Address on mainnet through `enterAddress` (env `STRIKE_SEED`, `STRIKE_LN_ADDR`, `WOS_SEED`, `WOS_LN_ADDR`, optional `*_AMOUNT_SATS`, default 5). No CI tag for iOS in the e2e repo.
- e2e `bitkit-e2e-tests/test/specs/mainnet/probe.e2e.ts`: `@probe_mainnet`/`@probe_mainnet_1`, probes LNURL/Lightning Address/node targets with `PROBE_SEED` and `PROBE_TARGETS_JSON`. See Gotchas: Android only.
- Unit: `BitkitTests/LnurlPayConfirmTests.swift` (one test), `BitkitTests/LightningAmountConversionTests.swift`.

## What proves it
- Pay: `SendSuccess` visible; `ActivitySpending` balance drops by the amount; `ActivityShort-0` shows `-`, `Sent` and the amount (ceil sats for msat amounts). Fixed amount: `CommentInput` absent, `ReviewAmount-primary` equals the fixed amount.
- Withdraw: `ReceivedTransaction` sheet acknowledged; `ActivitySpending` rises; `ActivityShort-0` shows `+`, the amount, `Received` and the `defaultDescription` text.
- Channel: server event `channelRequest:action`, peer connects, `SpendingBalanceReadyToast`, `ExternalSuccess` acknowledged, `ActivitySpending` shows the pushed amount (20 001).
- Auth: text `Signed In` and the server `login` event.
- Journey: toast `LnurlPayNoCapacityToast` with the capacity text, `RecipientManual` still visible, no `SendNumberField` or `SendConfirm`.

## Not covered by tests
- Failing then recovering pay callback with the send failure screen and Retry: no journey or e2e on LNURL (journeys README says so).
- `LnurlWithdrawFailure` screen (Support, Scan QR), withdraw callback errors, withdraw min > max toast, withdraw/pay refusal toasts for node not running: not covered.
- LNURL-auth `register`, `link` and error toast; Cancel; only `login` is exercised.
- LNURL-channel parse failure state, Cancel, `connectPeer` failure; the pure-LNURL path with a QR from the camera or photo library.
- Lightning Address on regtest: not covered locally (mainnet spec only, not in CI for iOS as far as the e2e repo shows).
- Comment display in activity detail: skipped in `lnurl.e2e.ts` (comment out, links bitkit-ios#277 and bitkit-android#417).
- LNURL pay via Contacts/Paykit and initial subscription payment: see `contacts.md`, `subscriptions.md`.

## Gotchas
- LNURL-pay and withdraw require a Lightning balance; with only onchain funds both are refused before any sheet opens.
- Fixed amounts are paid verbatim in msats; UI shows ceil sats (min) and floor sats (max). Sub-sat inversion counts as fixed.
- The camera permission dialog appears on first Send/Scan; the e2e helper `enterAddress` only dismisses it on Android (`handleAndroidAlert`).
- `ScanPrompt` exists only when `Env.isE2E`; `enterAddressViaScanPrompt` taps `Scan` then `ScanPrompt`.
- A decode failure in `handleScannedData` surfaces as the generic QR error toast from `ScannerManager` (`other__qr_error_header`), not an LNURL message. LNURL bech32 parsing itself is in BitkitCore (not read, unverified).
- `probe.e2e.ts` helpers shell out to `adb` (`test/helpers/probe.ts`) and `docs/mainnet-probe.md` builds an APK, so this suite is Android only; not runnable on iOS.
- `lnurl-server` fixture in `bitkit-docker` issues memo invoices; description-hash checks need another endpoint (`journeys/README.md`).
- Two different LNURL servers are in use: the in-process `lnurl` npm server on port 30001 (e2e repo) and the `bitkit-docker` fixture on port 3010 (journeys).
