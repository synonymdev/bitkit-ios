# Coin Selection

`manual-wallet-switch.xml` is shared with Android. It covers manual selection after switching
to Savings, repeated Back and swipe, Tags navigation after selection, and automatic mode.
No payment is submitted. iOS can open the picker on the wallet switch; Android opens it on
the next swipe. Both return to confirmation when backing out of that picker.
The iOS picker has no accessibility identifiers; assert its visible "Coin Selection" title.

Use a disposable regtest wallet with confirmed Savings coins, sufficient Spending balance,
and a fresh external unified invoice. See [backend setup](../README.md#backend-preconditions).
Open the invoice with `xcrun simctl openurl <device> "<unified payment URI>"`. Coin Selection is
under Settings > Advanced. On confirmation, use Show Details to access the funding-source selector.

## Retry Failure

This additional manual check needs deterministic failure of the next available-coin load, which
the journey environment does not provide. After switching a unified invoice to Savings and
returning from the picker with Back, fail that load and swipe. Verify an error toast appears,
Savings remains selected, and no warning, authorization, or payment occurs. Restore coin loading
and swipe again: the picker must reopen, with Savings still selected. Close without paying.
