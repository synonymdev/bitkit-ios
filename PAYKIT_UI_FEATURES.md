# Paykit UI Features - Quick Reference

This guide shows where to find all Paykit features in the Bitkit iOS app.

## Main Navigation

### Paykit Dashboard
**Location:** Settings → Paykit (or Drawer Menu → Paykit)

**Features:**
- Stats overview (pending requests, subscriptions, contacts)
- Quick access cards for all Paykit features
- Pubky-ring connection status
- Sections:
  - **Payments**: Payment Requests, Noise Payment, Contacts, Discover
  - **Identity & Security**: Endpoints, Key Rotation

## Payment Features

### Payment Requests
**Navigation:** Paykit Dashboard → Payment Requests

**Features:**
- Create new payment requests
- View pending/active requests
- Share requests via QR code or link
- Pay incoming requests
- Request history

### Noise Payment
**Navigation:** Paykit Dashboard → Noise Payment

**Features:**
- Send payments to Pubky contacts via Noise protocol
- Select contact from list
- Enter amount and memo
- Execute Noise-encrypted payments

### Payment Receipts
**Navigation:** Paykit Dashboard → Receipts (or Activity → Paykit tab)

**Features:**
- View all Paykit payment receipts
- Filter by sent/received
- View receipt details (preimage, proof, etc.)
- Receipts also appear in main Activity list

## Subscription Features

### Subscriptions
**Navigation:** Paykit Dashboard → Subscriptions

**Features:**
- Create recurring subscriptions
- View active subscriptions
- Manage subscription settings
- View payment history
- Enable/disable subscriptions

### Auto-Pay
**Navigation:** Paykit Dashboard → Auto-Pay

**Features:**
- Enable/disable auto-pay globally
- Set global daily spending limits
- Configure per-peer spending limits
- Create auto-pay rules
- View auto-pay history

## Contact & Discovery

### Contacts
**Navigation:** Drawer Menu → Contacts (or Paykit Dashboard → Contacts)

**Features:**
- View Paykit contacts
- Import contacts from Pubky-app
- View contact payment methods
- Send payments to contacts

### Contact Discovery
**Navigation:** Paykit Dashboard → Discover

**Features:**
- Discover new payment methods from Pubky directory
- Search by pubkey
- View discovered contacts
- Add to contacts list

## Identity & Security

### Profile Management
**Navigation:** Paykit Dashboard → Profile (or Settings → Profile)

**Features:**
- **Profile Import**: Import profile from Pubky-app
- **Profile Edit**: Edit and publish your profile
- View your pubkey and profile info

### Private Endpoints
**Navigation:** Paykit Dashboard → Endpoints

**Features:**
- View published payment endpoints
- Add/edit payment endpoints
- Configure endpoint settings

### Key Rotation
**Navigation:** Paykit Dashboard → Key Rotation

**Features:**
- View key rotation settings
- Configure rotation schedule
- Manual key rotation

## Pubky-Ring Integration

### Authentication
**Location:** Paykit Dashboard → Pubky-ring Connection Card

**Features:**
- **Same Device**: Connect if Pubky-ring is installed
- **QR Code**: Cross-device authentication via QR
- **Manual Entry**: Enter session manually
- **Share Link**: Shareable link for cross-device auth

**Status Indicators:**
- ✅ Connected (green)
- ⚠️ Not Connected (yellow)
- ❌ Pubky-ring Not Installed (with fallback options)

## Activity Integration

### Activity List
**Location:** Main Activity Tab

**Features:**
- Paykit receipts appear alongside Lightning/Onchain activities
- Filter by "Paykit" tab to see only Paykit receipts
- Unified timeline showing all payment types
- Receipt details accessible from activity list

## Settings Integration

### Paykit Settings
**Location:** Settings → Paykit

**Quick Access:**
- Paykit Dashboard
- Auto-Pay Settings
- Spending Limits
- Session Management

## Key UI Highlights

1. **Paykit Dashboard** - Central hub for all Paykit features
2. **Unified Activity** - Paykit receipts integrated with main activity
3. **Cross-Device Auth** - QR code and link support for Pubky-ring
4. **Background Processing** - Subscriptions and polling work in background
5. **Graceful Degradation** - Works even when Pubky-ring not installed

## Testing the Features

### Quick Test Flow:
1. Open Paykit Dashboard from Settings
2. Check Pubky-ring connection status
3. Create a payment request
4. View it in Payment Requests list
5. Check Activity tab → Paykit to see receipts
6. Explore Contacts and Discovery
7. Configure Auto-Pay settings
8. Test cross-device auth (QR code)

All features are fully functional and ready for testing!

