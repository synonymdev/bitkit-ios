# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.2...HEAD
[2.3.2]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.1...v2.3.0
[2.2.1]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.1.2...v2.2.0
