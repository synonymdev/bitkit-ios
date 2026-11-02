# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.1.0] - 2026-11-02

### Added
- Bitkit now shows a toast when a pending payment request expires. #1051
- On-chain sends without Lightning channels now show a bitcoin-themed Connecting to network view. #1152
- Allowances can be turned off from Dev Settings. #1171
- Allowances: set a per-payment and a monthly limit for a Paykit contact so their payment requests within the limits are paid automatically. #799
- Bitkit can now hide all toasts from Dev Settings. #829
- Allowances now activate automatically on the receiving wallet: when a contact sets up an allowance for you, Bitkit accepts it and lets you know. #841

### Changed
- The wallet picker on the send amount screen now shows a dropdown arrow instead of the switch icon. #1041
- Updated the terms of use to cover USDT support and third-party services. #1042
- Payment requests from a shop now show the payee under To instead of Contact. #1052
- Hardware wallet screens now show the current Jade Plus and Trezor Safe 7 devices. #1094
- Pubkys from Pubky Ring now show "Unlink pubky" instead of "Delete Profile" in Edit Profile, making clear the pubky stays in Pubky Ring. #1108
- Transfers to spending now point to Manual Setup, since Blocktank no longer sells Lightning channels, and a forced close of a Blocktank connection no longer leaves funds stuck. #1127
- Profile deletion avoids an intermediate Paykit capability update, retains failed-operation recovery, and keeps cleanup bound to the identity being deleted. #979

### Fixed
- Keep contact selection disabled while resolving a payment, stabilize payment amounts, and keep USDT receive controls and swipe navigation usable across screen sizes. #1003
- Keep Bitcoin and Lightning receiving details up to date when USDT address preparation is temporarily unavailable. #1004
- Toasts with a close button keep their text clear of the button in every language and text size. #1017
- Receiving USDT now slides between the address, network, amount and fee screens, like the Bitcoin receive flow. #1018
- Swiping over the USDT receive QR now moves to the previous tab. #1020
- Reduce delays while authorizing Paykit payments and delivering payment confirmations, and resume loading contacts after payment review. #1025
- Swiping past the first or last Receive tab now wraps around to the tab at the other end. #1027
- Updated USDT bridge validation and recovery, with clearer errors when deposit liquidity is unavailable. #1032
- Fixed payment requests losing their amount or getting stuck on loading after unlocking the app, and kept in-flight payments busy after unlock. #1039
- Bitkit now shows Paykit again after updating on wallets where it had been turned off. #1045
- Show a network reminder when copying a USDT receive address. #1047
- Pause automatic contact updates during Paykit payment review or submission, resume them safely afterward, prevent crashes when backup observation starts or stops, and return to the connections list after closing a Lightning connection. #1054
- Sending to a USDT address now continues in the same send sheet, titled Send USDT. #1055
- The USDT amount keypad now sits right above Continue, as on the Bitcoin amount screen. #1056
- Swipe To Pay stays completed while a USDT send warning or the payment PIN is shown. #1057
- Tapping the transaction ID in USDT activity details now copies it. #1058
- On the expanded USDT payment review, the fee note no longer crowds Hide Details, and long details scroll above a pinned Swipe To Pay. #1060
- Background payment-request updates now give priority to payment review and submission. #1066
- USDT sends over half your USDT balance now warn about the USDT balance instead of the total balance. #1069
- Keep payment requests responsive during review and payment progress visible after app unlock. #1070
- Show USDT balances quietly with consistent decimals, a currency symbol on Home and an unknown marker until the balance loads. #1077
- Use a single BTC/USD denomination toggle when creating payment requests and subscriptions. #1078
- Keep payment request state fresh after preparation failures without waiting for message delivery. #1081
- Incoming Lightning payments can use the whole channel instead of 10% of it, on channels opened after this update. #1086
- Scale received-payment artwork consistently across Bitcoin, Lightning and USDT sheets. #1092
- Keeps LNURL payment reviews stable when screens change and prevents stale image scans or repeated swipes from replacing or duplicating a payment. #1099
- Payment requests blocked by an earlier on-chain payment can be retried after that payment is resolved. #1107
- Recovered on-chain payments show their own sent amount instead of another payment’s draft. #1112
- Fixes overlapping payment-history refreshes that could cause long delays and repeated activity work. #1114
- Shows USDT backup and submission errors immediately while preserving the original pending payment for recovery. #1115
- Recover missing transaction details from the local wallet for restored payments while keeping background synchronization limited to cached details. #1116
- Keep ordinary USDT recovery backups independent of Pubky and resume the same signed payment after backup failures. #1118
- Show contact profiles and allow saving while optional payment details are still loading. #1119
- Show the last known Home balance while USDT balances and exchange rates refresh. #1131
- Stop showing a system banner for a due subscription payment or an allowance limit while Bitkit already shows the request in the app. #1136
- Allowances now load their contacts right after sign-in, announce every allowance accepted automatically, keep their limits and Auto-paid totals on busy wallets and across a wallet restore, and leave requests they can't pay over Lightning for manual payment. #1141
- A manual Lightning payment restored from a backup taken just before it was sent keeps its allowance hold, so the same request cannot be paid twice. #1163
- Home marks the balance with a soft shimmer while it updates, without moving the screen. #1168
- Restoring a backup made on Android now brings back your activity history, channel orders, address types and display settings. #1173
- Automatic allowance payments also check spending, paid requests and ended allowances recorded in the wallet and its backup, and pause with a Resume option when allowance records are older than ones the wallet already used. #1175
- Bitkit shows the updated Tether artwork and USDT introduction, colours send reviews by the paying wallet, and always shows Request Payment, opening Add Contact when you have no contacts. #1179
- Face ID and Touch ID now start automatically once when reopening a locked wallet, with correctly spaced PIN fallback controls after authentication fails. #788
- Prevented stale backup failure alerts from appearing after unlocking the device. #800
- Reset server settings and temporary settings-screen state, and discard pending server changes when wiping a wallet. #871
- Fixed misleading success feedback when Send rejects a Pubky authentication QR code. #896
- Improved USDT scanning, amount formatting, bridge errors, refund feedback, accessibility and payment retry handling. #973
- Eligible initial USDT subscription payments continue after subscribing without a second swipe while retaining authentication and safety checks, with retryable unpaid periods, expired requests retained in payment history, and only paid periods shown in subscription details. #981
- Refresh payment requests promptly when USDT payment or proof state changes. #982
- Improved USDT deposit and payment request readability and recipient scrolling with enlarged text. #983
- Boost only replaces outgoing transactions this wallet sent.

### Security
- Public payments now require a separate opt-in and use a reserved Bitcoin address, while private contact payments can remain enabled independently. #1095







## [3.0.1] - 2026-10-19

### Fixed
- Pause automatic Paykit refresh and publication during profile deletion, then resume if the profile remains signed in. #954
- Fixed the Pubky sign-in sheet sometimes disappearing when a sign-in link opened Bitkit from a closed state. #966
- On-chain payments no longer fail with an unknown outcome after Bitkit returns from the background. #967
- Preserved pending USDT payment protection after backup restore and kept bridge support details safely formatted. #969
- Opening another link while a Pubky sign-in is pending no longer drops the sign-in; the other link opens after it. #985
- An on-chain payment whose request ended before it reached the network can now be cancelled, which sends its coins back to the wallet so it no longer blocks new on-chain payments. #986
- Payment links opened while Bitkit is locked now open for review instead of being paid with QuickPay. #992
- Copy plain USDT receiving addresses and share them with the selected network, requested amount and payment QR code. #997

## [3.0.0] - 2026-10-16

### Added
- Bitkit now opens Pubky marketplace setup links directly into explicit watch-only account consent. #722
- Added support for creating a Pubky identity from app-authorized and direct Pubky signup requests, with approval, a relay timeout and protection against overlapping signup attempts. #724
- Bitkit can now propose recurring subscriptions to Paykit contacts. #736
- Added support for restoring wallets from Standard and Compact SeedQR codes. #760
- Added support for pairing Blockstream Jade and Jade Plus hardware wallets over Bluetooth, including watch-only balances, address verification and on-device transaction signing. #765
- Open Pubky contact links directly in Bitkit to add a contact or view an existing one. #768
- Bitkit can now use a pubky you already keep in Pubky Ring, and shares its own pubky with Pubky Ring. #774
- Dev Settings can now move subscription renewals forward by a number of days, so the next billing period can be tested without waiting for it. #798
- Opt in to USDT in Settings to send and receive with fees paid in USDT, Paykit contact payments and requests, subscriptions, cross-network deposits, optional Earn address sharing, and encrypted payment recovery backups. #884
- Support Pubky grant signup links through the existing authorization and profile setup flows. #900
- Bitkit on iPhone can now open Pubky sign-in requests from web pages, such as connecting the Lock Server in the Shop. #939

### Changed
- Improved Home pull-to-refresh feedback and added on-demand exchange-rate updates. #532
- Incoming payment requests are checked every ten seconds while the app is open and online. #769
- Incoming Payment Requests now show who the request is from and what it is for under the amount. #789
- Paykit contacts, payment requests and subscriptions are now on by default. #802
- The Payment Request sheet now always shows what a request is for, reading "Not specified" when the request has no note. #817
- Share Paykit contacts and payment state with authorized apps while keeping wallet keys private, restore contacts when re-importing an identity, prepare incoming payments in the payment sheet, support one-time payment deadlines, prioritize payment submission over background synchronization, distinguish temporary restoration failures from expired sessions, preserve subscription reminders through retries, and label received payments with their Paykit contact. #856
- Jade hardware wallets now display device artwork that matches the app's hardware wallet design. #878
- Pubky authorization dialogs now name the requesting service, group permissions and details under clear headings, and show a compact profile card. #880
- Accepting a subscription now sends the first payment in the same swipe when it is paid on-chain, as it already did over Lightning. #881
- Refine Earn and USDT payment layouts, support plain USDT addresses in scanning and manual entry, and let requests and subscriptions choose individual receiving methods. #942

### Fixed
- Use USDT labels and styling when preparing and entering payments, with readable messages for bridge issues. #948
- Keep wallet backups consistent during Paykit activity and preserve pending changes until they are backed up. #950
- Incoming on-chain transactions that confirm before being seen in the mempool now show the received notification. #588
- Payment requests now provide safe failure diagnostics and show an error when requested payment details remain unavailable. #721
- Fixed the transfer to spending flow creating a Blocktank order every time you tapped Continue, so an order is now only created when you confirm the transfer. #738
- Incoming payment requests appear sooner while the app is open, without unnecessary wallet backup uploads. #748
- Improved Pubky identity discovery by periodically refreshing existing identity records while Bitkit is open. #753
- Subscriptions now match their designs: rows scroll under the tab bar and the floating buttons, the delete sheet carries the trash illustration, dates drop the year, and the amount step gains a unit switch for entering amounts in fiat. #754
- Fixed private payment connections reusing a previous wallet’s key after resetting the wallet. #761
- Hardware wallet send confirmation now uses the orange accent color instead of blue. #771
- Spending confirm now shows the amount of bitcoin that leaves the wallet when a transfer uses send-all funding, and the transfer record uses that same amount. #772
- Aligned the profile screens and the home header spacing with the latest designs. #781
- Transfer to spending no longer pays more than the confirmed amount: if fees rise before the swipe, it explains the increase and waits for another swipe. #783
- Preserve Paykit subscription and pending payment state in wallet backups, and retain saved data when it cannot be read or restored. #786
- Clipboard reading now runs after unlocking Bitkit with a PIN. #790
- Fixed a sheet closing right after it opened when it appeared just after another sheet was dismissed, such as a subscription proposal arriving after you tapped Later on the QuickPay intro. #793
- Payout authorization no longer fails when the initial wallet sync times out. #794
- Fixed Paykit recovery after connection loss or device clock changes to preserve profiles and contacts, retry saved sessions with visible loading feedback, and improve billing reminder timing, including preserving the previous identity when a switch fails. #796
- Paying a contact now reliably offers Request or Pay when the contact accepts requests, and opens the amount screen faster with a loading indicator. #809
- Fixed a paid Paykit payment request sometimes reappearing as pending after closing the send screen, which could lead to paying it twice. #820
- Keep Paykit requests with unsupported payment deadlines in history and explain why their subscriptions cannot be accepted. #823
- Fixed unpaid Payment Requests appearing as completed payments or getting stuck after a failed send or private-link recovery. #826
- Deleting a contact now stops private payment requests until you add that contact again, and background refreshes no longer restore deleted contacts. #830
- Fixed wallet setup getting stuck at 100% after retrying a failed startup. #831
- On-chain sends now keep uncertain broadcast attempts pending and show the transaction ID, preventing another payment while the outcome is unresolved. #844
- A canceled subscription now stays active until its paid period ends, then expires. #846
- Fixed swipe to pay being usable before the network fee rate had loaded, which made on-chain payments fail with "Fee rate not set". #847
- Fixed the wallet staying on "Connection issues" after a failed node start until the app was relaunched; it now retries when the app returns to the foreground. #848
- Fixed slow contact imports by saving prepared contacts locally, skipping your own profile and keeping failed imports available for retry. #851
- Activity metadata restored from a React Native wallet stays saved for later recovery without repeatedly rebuilding payment history or uploading unchanged backups. #852
- Pubky profiles and contacts load faster: Pubky Ring identities appear at once, adopting one no longer waits on other lookups, the profile screen shows your cached name and avatar while it loads, and Contacts shows your saved contacts straight away while their profiles load. A contact import that finishes after you leave it no longer takes you to Pay Contacts. #854
- Fixed Paykit failures after wiping a wallet and false profile errors when cancelled work finishes after signup. #855
- New incoming Payment Requests open automatically while Bitkit is unlocked, without waiting for the rest of the refresh to finish. #858
- Opening Contacts keeps your saved profile on loading or Retry while it reconnects instead of offering profile setup. #864
- Saving a profile edit with a new avatar no longer opens Create Profile, and a contact deleted while its profile loads keeps its new profile when added back. #869
- Bitkit now offers each clipboard copy only once and waits for confirmation before contacting payment endpoints. #870
- Leaving Contacts no longer shows an error for a cancelled contact load. #873
- Pay fixed-price Paykit requests using the quoted Bitcoin amount, show feedback for unavailable destinations, and prioritize linking for newly added or explicitly refreshed contacts. #887
- Pause automatic contact and payment-request refreshes in the background without delaying payment and wallet-sync completion, preserve pending work until resume, and avoid redundant startup endpoint publication. #888
- Fixed untranslated plural templates in transaction details and backup failure messages for affected languages. #897
- Keep your public profile visible after restarting while private payment data is still reconnecting. #898
- Fixed an incorrect send error appearing after closing a successful Lightning payment. #899
- Report identity-key access errors before enabling contact payments. #901
- Keep manual coin selection required after returning from the coin picker without choosing coins. #903
- Stopped unnecessary background retries for unavailable contacts while preserving queued message delivery. #911
- Payment requests below the minimum Bitcoin amount now show the minimum and close payment preparation. #913
- Verified hardware-wallet payments can finish locally while their payment proofs await delivery. #914
- Retain exact Bitcoin retry fees so accepted payments can finish local recovery while wallet history is still catching up. #915
- Bitcoin sends keep a single activity entry with their contact and fee when wallet synchronization overlaps payment completion. #916
- Fixed force-closed channels failing to claim pending payments on-chain. #930
- Receive invoices now keep the latest amount and note during overlapping refreshes, with retry available when invoice creation fails. #933
- Discover Shop sellers from buyer interaction markers on app resume and payment-request polls, preserving edited and removed contacts, and refresh shared contacts before opening contact links. #934
- Restored Arabic translations and added missing translations across languages. #938

### Security
- Paykit payment approvals remain tied to the reviewed proposal when private state changes. #921
- Updated the Lightning node with upstream security fixes. #928

## [2.5.1] - 2026-10-13

### Fixed
- Updated LDK Node to 0.7.0-rc.66.1 for the upstream Lightning security fixes. #924

## [2.5.0] - 2026-09-10

### Added
- Added receiver-specific Paykit contact support for Bitkit wallet and server integrations. #620
- Bitkit now creates, names, backs up, and manages separate watch-only Bitcoin accounts and securely delivers signed setup claims to Paykit servers. #630
- Incoming Paykit payment requests can now be reviewed and approved through the existing payment flow. #637
- Improved Lightning send failures with clearer localized messages and a retry action that refreshes payment routing before trying again. #652
- Passphrase-protected (hidden) Trezor wallets can now be paired from the connect flow, each appearing as its own watch-only balance with its own label, activity and removal, and asking for its passphrase again when a transfer needs signing. #662
- Incoming Paykit payment requests now stay discoverable until handled, and connected contacts can send new private requests from the invoice flow. #676
- The name you give a hardware wallet is now included in your backup and comes back when you pair the device again, and removing a hardware wallet asks first whether to keep its name and tags in your backup. #681
- Payments made from incoming private payment requests now send a payment proof back to the requester. #683
- Bitkit can now review, manage, and pay recurring payment requests from Paykit contacts, with on-chain fees shown before confirming the first payment and unresolved payments protected from accidental retries. #685
- Added on-chain send support for paired Trezor wallets, including transaction approval on the device. #688
- Added a Trezor Receive tab with fast watch-only addresses and on-device verification. #693

### Changed
- Hardware wallet transactions are now stored with the rest of your activity, so they keep their tags, contacts and transaction details, show inputs and outputs under Explore, disappear when a transaction is replaced, and a transfer to spending funded from a hardware wallet shows as a single transfer. #648

### Fixed
- Updated the Receive screen's QR and details toggle to match the intended design, so "Show Details" is now a tertiary button and "Show QR Code" a primary button with a QR icon. #635
- Improved Pubky profiles, contacts, imports, and contact payments with unified payment settings and updated layouts. #636
- Fixed profile deletion being blocked when private Paykit contact cleanup could not complete. #640
- Fixed Paykit Server authorization, removed duplicate service names from permission summaries, and made private payment request connections establish promptly after contact discovery. #653
- Fixed address type monitoring and primary address type changes getting permanently stuck after a temporary wallet sync timeout. #667
- Tags you add to hardware wallet activity are now included in your backup, and older backups are upgraded automatically the first time you restore them. #674
- Contact payments now isolate malformed receiver markers, validate request amounts and available capacity before payment, and retain cleanup of private details when switching to public-only sharing. #684
- Transfers to spending now offer a maximum amount and receiving capacity your savings can actually cover the fees for, so transferring your full balance no longer fails with an insufficient funds error, and the hardware wallet transfer amount is held to that maximum instead of accepting any amount you type. #686
- Swipe To Transfer now stays on the spinner after you confirm a transfer to spending. #690
- Hardware-wallet send now clearly shows fee and funding-source preparation and prevents confirmation until the selected fee is ready. #708
- Improved receive invoice routing so Lightning and additional spending capacity flows respect ready inbound liquidity and show clearer capacity errors. #711
- A hardware-wallet payment that fails to broadcast now tells you the payment was not confirmed and lets you retry or leave, instead of locking the send screen. #729
- Paid Blocktank channel orders now include a wallet-owned address for refunds if they expire before being claimed. #732

### Security
- QuickPay stays PIN-free under a configurable daily spend limit; once that limit is reached, payments open Confirm instead. #672
- Added app-scoped Pubky authorization and secure sign-out, preserved contact payments during node startup, and fixed missing payment requests in history. #697

## [2.4.1] - 2026-08-21

### Security
- Lightning no longer automatically starts from outdated channel monitor data after a storage mismatch. #664
- Wallet backups no longer fall back to unauthenticated VSS when LNURL-auth is missing. #665
- Shop checkout now accepts only payment requests from the trusted Bitrefill embed origin. #668
- Wallet backups now use VSS 0.5.23, which rejects unauthenticated encryption. #673

## [2.4.0] - 2026-07-16

### Added
- Added Trezor hidden-wallet passphrase selection and an on-chain event watcher for live xpub activity. #574
- Show paired Trezor hardware wallet balances and activity on the home screen, with sheets to enter the pairing code and to notify incoming hardware wallet transactions. #605
- Added a Hardware Wallets settings screen, reachable from Settings ▸ General ▸ Payments, to view, rename, and remove paired devices. #612
- Connect a Trezor hardware wallet from the home suggestion card or Hardware Wallets settings to watch its balance, with a guided pairing flow that finds the device, enters the one-time pairing code, and labels the funds. #614
- Transfer funds from a paired Trezor hardware wallet to your spending balance, signing the on-chain funding transaction on the device. #616

### Changed
- Toast notifications now arrive with a gentle spring settle, fade out quickly, and render their accent colors true to the design instead of washed out. #592
- Error toasts now use Bitkit's brand color instead of a separate red accent, matching the design across all toast types. #594
- Update FX rates endpoint to no longer use old Blocktank service. #624

### Fixed
- Hardware wallet transfers to spending now use a faster on-chain fee rate so funding confirms more reliably. #634
- Amount entry across the send, spending, LNURL, and channel-funding screens now caps the number pad at your available balance and briefly warns when you try to enter more than you can send. #346
- Channel close and transfer activities, including force closes, now offer an Explore button so the on-chain transaction ID and block explorer details are accessible. #361
- Fixed private contact payment preferences so the toggle only updates after endpoint publication or removal succeeds. #583
- Connection Details now shows the short channel ID and the correct channel point for Lightning connections. #587
- Sending no longer waits indefinitely or crashes when Lightning channels stay unavailable: Bitkit now prefers Lightning while the peer reconnects, then falls back to an onchain payment when possible or shows the connection issues screen after a short wait. #590
- Fixed Transfer to Spending showing a zero maximum when your on-chain balance exceeds the LSP's channel limit, and the displayed available balance now matches the amount you can actually transfer. #595
- Re-adding the Suggestions widget now restores the default suggestion cards when all of them had been dismissed. #596
- The Receive screen now keeps your selected Savings or Spending tab after editing the invoice amount, instead of resetting to Auto. #599
- Recovery mode now has a Reset Network Graph option that re-downloads the Lightning network graph to fix "route not found" errors. #600
- Bitkit now shows the optional update prompt during onboarding too, so it is no longer missed on a fresh first launch. #601
- Improved hardware wallet settings and removal, connection guidance, Bluetooth interruption recovery, and signed-transfer broadcast retries. #621
- Fixed the Czech backup-failure notification so its retry countdown displays properly instead of showing raw placeholder text. #628
- Fixed a freeze on the Electrum and RGS server settings screens when entering a long hostname. #629





## [2.3.2] - 2026-07-14

### Fixed
- Improved Lightning probe route fee reporting. #622
- Improved Lightning payment route selection reliability. #623

## [2.3.1] - 2026-06-26

### Fixed
- Improved LNURL-pay invoice validation. #607
- Improved LNURL-pay payment handling. #610

## [2.3.0] - 2026-06-04

### Added
- Add UI for offline state in various flows #528
- Support publishing public Paykit endpoints and paying pubky contacts through public payment endpoints. #531
- Add Pubky Ring auth callbacks and keep canceled auth attempts from disconnecting profiles. #537
- Added contact-first send, activity contact assignment, contact avatars in activity, and payment preference controls. #539
- Contact payments now prefer private Paykit endpoints with dedicated receiving details for each contact when available. #549
- Added BTCPay store connection so stores can register Bitkit receive descriptors from scanned setup QR codes. #561
- Added a Legacy Recovery option in developer settings to help recover funds from affected legacy channel closes. #572
- Redesigned the Price, Headlines, Blocks, and Weather widgets to the Figma v61 look and added matching Bitcoin home-screen widgets for each, with refreshed preview and edit flows.
- Restore pubky sessions from wallet backups and improve iOS pubky profile, contacts, and clipboard flows #527
- Pubky profile onboarding with contact sync, import, and editing #476
- Add transfer from savings button on empty spending wallet when user has on-chain balance #523

### Changed
- Beautify activity header: now uses overlay blur, gradient fade, and a single composited shadow above the scrolling list #534
- Added swipe gestures on the tabs in settings and shop and polished the header areas on those screens #550
- Redesigned the Bitcoin Calculator widget to v61 design and replaced the OS keyboard with a dark-themed in-app numpad #554
- Hide experimental Paykit profile, contacts, and contact payment controls behind a developer setting. #556
- Update funding screen: replace Advanced with Manual Setup, update description text, add no-funds alert dialog #520
- Update external channel success screen: rename title to "Channel opening", add dedicated "Spending Balance" nav title, and replace switch illustration with lightning bolt #521
- Use middle-ellipsis truncation for addresses on the receive screen #517

### Fixed
- LNURL withdraw and other prefixed LNURL QR codes scan correctly on iOS. #581
- You can now tap to copy the channel ID, channel point, node ID, order ID, and transaction ID from a Lightning connection's details. #578
- In widget edit mode, the settings button is now disabled only for the suggestions widget, and opening settings for widgets without options goes straight to the preview. #579
- Replaced the third-party Zip dependency with a native ZipService built on NSFileCoordinator for log archive creation. #526
- Fixed on-chain sends so dust change can no longer turn a partial payment into a max-balance send. #536
- Improved public contact payment flows for manual Pubky entry, RBF activity display, and newly opened Lightning channels. #539
- The Support page now shows the current copyright year automatically. #570
- Fix probe results and add keysend probes #522
- Fix design: minor UI fixes #525

## [2.2.1] - 2026-05-05

### Fixed
- Fixed on-chain sends so dust change can no longer turn a partial payment into a max-balance send #536

## [2.2.0] - 2026-04-07

### Fixed
- Fix keyboard and UI issues in the calculator widget #513
- Preserve msat precision for LNURL pay, withdraw callbacks and bolt11 #512

[Unreleased]: https://github.com/synonymdev/bitkit-ios/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/synonymdev/bitkit-ios/compare/v3.0.1...v3.1.0
[3.0.1]: https://github.com/synonymdev/bitkit-ios/compare/v3.0.0..v3.0.1
[3.0.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.5.1..v3.0.0
[2.5.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.5.0...v2.5.1
[2.5.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.4.1...v2.5.0
[2.4.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.4.0...v2.4.1
[2.4.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.1...v2.3.0
[2.2.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.1.2...v2.2.0
