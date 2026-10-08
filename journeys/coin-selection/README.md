# Coin Selection

`manual-wallet-switch.xml` is shared with Android. It covers manual selection after switching
to Savings, repeated Back and swipe, Tags navigation after selection, and automatic mode.
No payment is submitted. iOS can open the picker on the wallet switch; Android opens it on
the next swipe. Both return to confirmation when backing out of that picker.

Use a disposable regtest wallet with confirmed Savings coins, sufficient Spending balance,
and a fresh external unified invoice. See [backend setup](../README.md#backend-preconditions).
Open the invoice with `xcrun simctl openurl <device> "<unified payment URI>"`. Coin Selection is
under Settings > Advanced. On confirmation, use Show Details to access the funding-source selector.
