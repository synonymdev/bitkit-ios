# Receive Liquidity Behavior

This document describes which Receive tabs the app offers and what it does when an invoice amount does not fit
the wallet's Lightning liquidity. The app no longer buys channels or instant receive (CJIT) liquidity from
Blocktank (synonymdev/bitkit-ios#1097), so a receive that needs liquidity falls back to Savings/onchain.

## Cases

- Opening the Receive sheet:
  - A new Receive sheet session starts from a fresh tab state.
  - If Auto is available, the default tab is Auto.
  - If Auto is unavailable, the default tab is Savings.
  - Temporary receive-session state, such as selected tab and nested navigation, must not survive closing and
    reopening the Receive sheet.

- Editing from Savings, Auto or Spending:
  - Editing sets the amount for the receive request and returns to the QR.
  - If the edited amount can be received over Lightning, the regenerated Spending invoice also includes that amount.
  - If the edited amount cannot be received over Lightning, the Auto and Spending tabs are no longer offered and
    the sheet falls back to the Savings tab with the onchain QR.

- Editing from a hardware receive tab:
  - Editing sets the amount for the hardware/onchain receive request.
  - Returning from the edit flow preserves the hardware receive tab when the edit originated there.
  - Editing from Savings or Auto while a hardware wallet is available still returns to the source tab, not the hardware tab.

- Lightning receive unavailable because there is no ready channel or ready inbound liquidity is `0`:
  - No Lightning invoice is created.
  - The sheet offers the Savings tab only (plus USDT or hardware when configured); there is no Spending or Auto tab.

- Ready channel, inbound liquidity greater than `0`, zero/variable amount:
  - A Lightning invoice is allowed, and the Spending and Auto tabs are offered.
  - A zero/variable Lightning invoice is allowed when inbound liquidity is greater than `0`, even though the sender could later choose an amount above the available inbound capacity.

- Ready channel, fixed amount less than or equal to inbound liquidity:
  - A normal BOLT11 invoice is created.
  - The unified QR includes Lightning.
  - The Spending tab shows the normal Lightning invoice.

- Ready channel, fixed amount greater than inbound liquidity:
  - No Lightning invoice is created, and the sheet falls back to Savings/onchain only.

## Invariants

- Spending and Auto tab availability, and the default tab, are based on whether a normal Lightning invoice can be
  created for the current receive amount.
- Ready channels alone do not imply Spending or Auto availability; fixed receive amounts must also fit within ready
  inbound liquidity.
- No receive path creates a CJIT entry or a Blocktank channel order.
