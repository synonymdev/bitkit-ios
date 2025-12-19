# Paykit User Guide

This guide explains how to use Paykit features in Bitkit for seamless payments with your Pubky identity.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Connecting Pubky-ring](#connecting-pubky-ring)
3. [Managing Sessions](#managing-sessions)
4. [Making Payments](#making-payments)
5. [Receiving Payments](#receiving-payments)
6. [Contacts](#contacts)
7. [Backup and Restore](#backup-and-restore)
8. [Troubleshooting](#troubleshooting)

---

## Getting Started

### What is Paykit?

Paykit connects your Bitkit wallet with your Pubky identity, enabling:
- Pay anyone using their Pubky username
- Receive payments to your Pubky profile
- Automatic payment method discovery
- Secure, encrypted direct payments

### Requirements

- Bitkit wallet with funds
- Pubky-ring app (optional but recommended)
- Internet connection

---

## Connecting Pubky-ring

Pubky-ring manages your Pubky identity. Connecting it to Bitkit enables full Paykit functionality.

### Option 1: Direct Connection (Same Device)

1. Open Bitkit
2. Go to **Settings** → **Paykit** → **Sessions**
3. Tap **Connect Pubky-ring**
4. Pubky-ring will open automatically
5. Review the permissions requested
6. Tap **Authorize**
7. You'll return to Bitkit with the session active

### Option 2: QR Code (Different Device)

1. Open Bitkit on Device A
2. Go to **Settings** → **Paykit** → **Sessions**
3. Tap **Connect via QR Code**
4. A QR code will appear
5. On Device B, open Pubky-ring
6. Scan the QR code
7. Authorize the connection
8. The session will be established

### What Permissions Are Granted?

| Permission | What It Allows |
|------------|----------------|
| Read | View your Pubky profile and follows |
| Write | Publish payment endpoints on your behalf |

---

## Managing Sessions

Sessions are secure connections between Bitkit and Pubky-ring.

### Viewing Active Sessions

1. Go to **Settings** → **Paykit** → **Sessions**
2. You'll see a list of active sessions
3. Each shows:
   - Connection date
   - Expiry date
   - Capabilities granted

### Refreshing a Session

Sessions expire periodically for security. To refresh:

1. Go to **Settings** → **Paykit** → **Sessions**
2. Tap on the session you want to refresh
3. Tap **Refresh**
4. Authorize in Pubky-ring if prompted

### Revoking a Session

To disconnect Bitkit from Pubky-ring:

1. Go to **Settings** → **Paykit** → **Sessions**
2. Swipe left on the session
3. Tap **Revoke**
4. Confirm the action

---

## Making Payments

### Pay to Pubky Username

1. Tap **Send** on the main screen
2. Enter the recipient's Pubky username (e.g., `@alice`)
3. Bitkit will look up their payment methods
4. Enter the amount
5. Choose a payment method (Lightning, On-chain, etc.)
6. Review and confirm

### Pay to Pubky URI

If you have a Pubky payment link:

1. Tap **Scan** or paste the link
2. Bitkit will parse the payment request
3. Review the amount and recipient
4. Confirm payment

### Payment Method Priority

Bitkit tries payment methods in order:
1. Lightning (fastest, lowest fees)
2. On-chain (fallback)
3. Direct/Interactive (if available)

---

## Receiving Payments

### Share Your Payment Info

1. Tap **Receive** on the main screen
2. Choose **Share Pubky Profile**
3. Your Pubky username and payment links are shown
4. Share via any app

### Publish Payment Endpoints

To let others pay you via your Pubky profile:

1. Go to **Settings** → **Paykit** → **Payment Methods**
2. Toggle on the methods you want to publish
3. Your Lightning and on-chain addresses will be published

### Privacy Options

| Setting | Effect |
|---------|--------|
| Public Endpoints | Anyone can see your payment methods |
| Private Endpoints | Only approved contacts can see them |
| Hidden | No payment methods published |

---

## Contacts

### Syncing Contacts from Pubky

Your Pubky follows can become payment contacts:

1. Go to **Settings** → **Paykit** → **Contacts**
2. Tap **Sync from Pubky**
3. Your follows with payment methods will appear
4. You can now pay them directly from the contact list

### Adding a Contact Manually

1. Go to **Settings** → **Paykit** → **Contacts**
2. Tap **Add Contact**
3. Enter their Pubky username or public key
4. Tap **Add**

### Discovering Contacts

1. Go to **Settings** → **Paykit** → **Contacts**
2. Tap **Discover**
3. Bitkit will find users in your network with payment capabilities
4. Review and add contacts

---

## Backup and Restore

### Creating a Backup

1. Go to **Settings** → **Paykit** → **Backup**
2. Tap **Export Backup**
3. Enter a strong password
4. Save the backup file securely

**Important:** This backs up your Paykit sessions and settings, not your wallet. Your wallet is backed up separately with your mnemonic phrase.

### Restoring from Backup

1. Go to **Settings** → **Paykit** → **Backup**
2. Tap **Import Backup**
3. Select your backup file
4. Enter the password used during export
5. Review what will be imported
6. Tap **Import**

### What Gets Backed Up?

- Active sessions
- Private payment endpoints
- Contacts

### What's NOT Backed Up?

- Wallet funds (use mnemonic backup)
- Payment history
- Cache data

---

## Troubleshooting

### "Session Expired"

**Cause:** Your Pubky-ring session has expired

**Solution:**
1. Go to **Settings** → **Paykit** → **Sessions**
2. Tap **Refresh** on the expired session
3. Authorize in Pubky-ring

### "Pubky-ring Not Installed"

**Cause:** Pubky-ring app is not installed on your device

**Solutions:**
1. Install Pubky-ring from App Store/Play Store
2. Use QR code method with Pubky-ring on another device
3. Some features work without Pubky-ring using fallback methods

### "Recipient Not Found"

**Cause:** The Pubky username doesn't exist or has no payment methods

**Solutions:**
1. Verify the username is correct
2. Ask the recipient to publish payment methods
3. Use their direct Lightning/Bitcoin address instead

### "Payment Failed"

**Cause:** Various reasons including insufficient funds, network issues, or recipient offline

**Solutions:**
1. Check your wallet balance
2. Check your internet connection
3. Try a different payment method
4. Wait and retry later

### "Rate Limited"

**Cause:** Too many requests in a short time

**Solution:** Wait a few minutes and try again

### "Backup Decryption Failed"

**Cause:** Incorrect password for backup file

**Solutions:**
1. Ensure you're using the exact same password
2. Check for typos
3. Try again carefully

### "Cannot Connect to Homeserver"

**Cause:** Network issues or homeserver is down

**Solutions:**
1. Check your internet connection
2. Wait and retry
3. Check Pubky status page for outages

---

## FAQ

### Is Paykit safe?

Yes. Paykit uses:
- End-to-end encryption for communications
- Secure key storage on your device
- Session-based authorization with expiry
- No storage of private keys on servers

### Can I use Paykit without Pubky-ring?

Some features work without Pubky-ring:
- ✅ Pay to users with public payment methods
- ✅ Receive payments if you've published endpoints
- ❌ Interactive/direct payments
- ❌ Signing requests

### How are my payment methods published?

Your payment methods are published to your Pubky homeserver, signed with your key. Only you can update them.

### Can others see my payment history?

No. Payment history is stored only on your device and is not shared.

### What happens if I lose my phone?

If you have a backup:
1. Install Bitkit on new device
2. Restore wallet with mnemonic
3. Import Paykit backup

If you don't have a backup:
1. Restore wallet with mnemonic
2. Reconnect to Pubky-ring
3. Your contacts and sessions will be fresh

---

## Glossary

| Term | Definition |
|------|------------|
| Pubky | Decentralized identity system |
| Pubky-ring | App managing Pubky identities |
| Session | Secure connection between Bitkit and Pubky-ring |
| Homeserver | Server storing your Pubky data |
| Noise Protocol | Encryption used for direct payments |
| Payment Endpoint | Address where you can receive funds |

---

## Getting Help

- **In-App:** Settings → Help & Support
- **Website:** https://bitkit.to/support
- **Community:** Join our Telegram/Discord

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Dec 2025 | Initial user guide |

