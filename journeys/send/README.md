# Send

`bip21-core-validation.xml` is shared with Android, with identical actions and fixtures. It verifies the shared decoder’s BIP21 validation through the app’s payment flow.

Deliver each `Open bitcoin:...` action with `xcrun simctl openurl <simulator-udid> "<uri>"`, replacing XML `&amp;` with `&` in the actual URI. Confirm the system’s Open in Bitkit prompt when shown. Dismiss introductory USDT, received-payment and backup prompts before starting. Inspect errors immediately. Use XcodeBuildMCP snapshots for payment state and screenshots for transient error toasts.

Use an onboarded regtest wallet with at least 100,000 sats in Savings and Quickpay disabled. The fixture address is not a destination to pay; close every payment sheet without confirming payment.

The native-binding tests also cover labels, proof-of-payment aliases and question marks in notes. App tests cover manual entry and the Shop rejection path; a malformed `payment_intent` from the real third-party Shop cannot be generated through this journey environment. Automatic clipboard prompting additionally has a manual check because arbitrary OS clipboard injection is not listed in the Capabilities table.

The shared journey verifies the recipient and amount in the payment UI. Metadata preservation, including `bitcoin:donation`, is asserted by the native-binding and app regression tests. Neither platform’s confirmation displays a standalone BIP21 note. Inspect the full recipient through its editable address field when the confirmation summary truncates it.

`contact-reselect-after-back.xml` checks that going back from a contact payment to the contact list lets the same or another contact be picked again without reopening Send. It needs Paykit UI, a Pubky profile and two saved contacts that publish public payment details; close the sheet from the amount screen without paying.
