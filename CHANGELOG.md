# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Pubky profile creation with BIP39 seed derivation and restore detection for existing profiles. #476
- Pubky Ring authentication with contact import overview, selection, and batch import. #476
- Profile view with QR code, bio, links, tags, and edit/copy/share actions. #476
- Contacts list with search, add, edit, delete, and alphabetical grouping. #476
- Pay Contacts onboarding step after profile creation and Ring import. #476
- Session restoration with automatic re-sign-in recovery. #476

### Changed
- Use middle-ellipsis truncation for addresses on the receive screen #517

## [2.2.0] - 2026-04-07

### Fixed
- Fix keyboard and UI issues in the calculator widget #513
- Preserve msat precision for LNURL pay, withdraw callbacks and bolt11 #512

[Unreleased]: https://github.com/synonymdev/bitkit-ios/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/synonymdev/bitkit-ios/compare/v2.1.2...v2.2.0
