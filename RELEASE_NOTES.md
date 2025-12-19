# Release Notes

## Paykit Integration Release

### Version 1.0.0 - Paykit Edition

**Release Date:** December 2025

---

## What's New

### 🎉 Paykit Integration

Bitkit now supports Paykit, enabling seamless payments with your Pubky identity:

- **Pay Anyone with Pubky**: Send Bitcoin to any Pubky username
- **Automatic Discovery**: Payment methods are discovered automatically
- **Secure Sessions**: Connect with Pubky-ring for full functionality
- **Direct Payments**: Encrypted peer-to-peer payments via Noise Protocol

### Features

#### Session Management
- Connect Bitkit to your Pubky-ring identity
- Cross-device authentication via QR code
- Automatic session refresh
- Secure session storage

#### Payment Discovery
- Automatic lookup of payment methods
- Support for Lightning, on-chain, and interactive payments
- Fallback chains when primary method fails
- Contact-based payments

#### Contacts
- Sync contacts from your Pubky follows
- Discover payment-enabled contacts
- Quick payments to saved contacts

#### Backup & Restore
- Export sessions and settings
- Password-protected encryption
- Cross-device migration support

---

## Improvements

- Enhanced error messages for payment failures
- Faster Lightning payment execution
- Improved network resilience
- Better battery efficiency for background sync

---

## Bug Fixes

- Fixed session expiry not being detected in some cases
- Fixed rare crash during QR code scanning
- Fixed memory leak in contact list
- Fixed incorrect amount display in some locales

---

## Technical Details

### New Dependencies
- pubky-noise 1.0.0
- paykit-lib 1.0.0
- paykit-interactive 1.0.0

### Minimum Requirements
- iOS 17.0+ / Android 9.0+
- Active internet connection
- Optional: Pubky-ring app for full functionality

### Known Limitations
- Interactive payments require Pubky-ring
- Some features limited without active session
- Background sync requires sufficient battery

---

## Upgrade Notes

### From Previous Versions

1. Update Bitkit to latest version
2. Wallet data migrates automatically
3. Connect to Pubky-ring to enable Paykit features
4. Sync contacts if desired

### New Users

1. Install Bitkit
2. Create or restore wallet
3. Install Pubky-ring (recommended)
4. Connect Paykit in Settings

---

## Documentation

- [User Guide](Docs/USER_GUIDE.md)
- [Setup Guide](Docs/PAYKIT_SETUP.md)
- [Troubleshooting](Docs/USER_GUIDE.md#troubleshooting)

---

## Feedback

We'd love to hear from you:
- In-app: Settings → Help & Support
- GitHub: Open an issue
- Community: Join our Telegram/Discord

---

## Contributors

Thanks to everyone who contributed to this release!

---

## Full Changelog

For the complete list of changes, see [CHANGELOG.md](CHANGELOG.md).

