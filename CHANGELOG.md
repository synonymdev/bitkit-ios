# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/synonymdev/bitkit-ios/compare/v2.4.0...HEAD
[2.4.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.1...v2.3.0
[2.2.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.1.2...v2.2.0
