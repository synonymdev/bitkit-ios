# Shop

Bitrefill embedded shop and BTC Map in a web view, the Buy Bitcoin card screen, and the BTCPay (SamRock) connection sheet.

## What it does
- Shop: intro, then a Discover screen with a Shop tab (4 featured cards + 22 category rows, hard-coded in `ShopDiscover.swift`) and a Map tab (BTC Map web view, `Env.btcMapUrl` = `https://btcmap.org/map`).
- A card or category opens `ShopMain`, a `WKWebView` on `https://embed.bitrefill.com/<page>/?ref=<Env.bitrefillRef>&paymentMethod=bitcoin&theme=dark&utm_source=bitkit`.
- The embed posts a `payment_intent` event with `paymentUri`. `ShopMain.handleMessage` passes it to `app.handleScannedData(..., scope: .paymentRequests)`, then opens the send sheet (`PaymentNavigationHelper.openPaymentSheet`). Supported: on-chain, Lightning, LNURL pay (`Bitkit/Utilities/ShopPaymentRequest.swift`).
- Navigation off `bitrefill.com` hosts is cancelled and a warning toast `other__shop__external_link_blocked` shows. Messages from any origin except `https://embed.bitrefill.com` main frame are dropped (`Bitkit/Utilities/ShopOrigin.swift`).
- Buy Bitcoin: `BuyBitcoinView` is an onboarding-style screen whose button opens `https://bitcoin.org/en/exchanges` in Safari (`// TODO: hide card .buyBitcoin` in code).
- BTCPay connection: a pasted/scanned/deep-linked SamRock setup URL opens `BTCPayConnectionSheet`; Connect registers the wallet's on-chain descriptor with the BTCPay store (`SamRockService.registerBitcoinOnchain`). Only Bitcoin on-chain is supported; other requested methods show a limited-support note.

## How a user reaches it
- Shop: Home `HeaderMenu` > `DrawerShop` (`DrawerView.swift:66`). Route is `.shopIntro` until `app.hasSeenShopIntro`, then `.shopDiscover`.
- Shop via Home suggestion card `Suggestion-shop` (only in the `.spending` card set, `Suggestions.swift:38`; same intro/discover rule).
- `ShopIntro` (id `ShopIntro`) > button `ShopIntro-button` sets `hasSeenShopIntro` and opens Discover.
- Discover tabs: `Tab-shop`, `Tab-map` (ids derive from English tab titles, `SegmentedControl.swift:24`). Cards/rows have no accessibilityIdentifier of their own (verified by grep in `ShopDiscover.swift`; `SuggestionCard` only sets `SuggestionDismiss`).
- Buy Bitcoin: Home suggestion card `Suggestion-buy` (present in `.empty` and `.onchain` sets) opens route `.buyBitcoin`; screen id `BuyBitcoin`, button `BuyBitcoin-button`.
- BTCPay: no menu entry. Reached by scanner/paste/deep link handled in `AppViewModel.swift:610` (scope `.unrestricted` only). Sheet ids: `BTCPayConnection`, `BTCPayConnect`, `BTCPayCancel`.

## Code
- Views: `Bitkit/Views/Shop/ShopIntro.swift`, `ShopDiscover.swift` (`ShopTab`, `ShopCategoryRow`), `ShopMain.swift`; `Bitkit/Components/ShopWebView.swift`; `Bitkit/Views/BuyBitcoinView.swift`; `Bitkit/Views/Sheets/BTCPayConnectionSheet.swift`.
- Routes (`Bitkit/ViewModels/NavigationViewModel.swift`): `.shopIntro`, `.shopDiscover`, `.shopMain(page:)`, `.buyBitcoin`. Wired in `Bitkit/MainNavView.swift:499,660-662`. Sheet: `SheetID.btcpayConnection` (`SheetViewModel.swift:22`).
- Logic: `Bitkit/Utilities/ShopOrigin.swift`, `Bitkit/Utilities/ShopPaymentRequest.swift` (`ScanHandlingScope`), `Bitkit/Services/SamRockService.swift` (`SamRockSetupRequest`), `Bitkit/Constants/Env.swift:403-404`.
- Cards: `Bitkit/Components/Widgets/Suggestions.swift`.

## How to drive it
- Journeys: none for Shop, Buy Bitcoin or BTCPay (grep of `journeys/` finds no shop/samrock/btcpay).
- E2E: none (grep of `bitkit-e2e-tests/test`, `docs`, `README.md` finds no shop/gift/bitrefill).
- Manual: simulator needs network to reach `embed.bitrefill.com`; `.offlineOverlay` shows when offline. A real `payment_intent` needs a Bitrefill checkout; the web view is the only source (could not determine a local fixture).
- BTCPay: needs a SamRock setup URL; public `http://` is rejected, local `http` allowed (`SamRockSetupRequestTests`).

## What proves it
- Shop: `ShopIntro` then `Tab-shop` visible; web view loads the chosen `embed.bitrefill.com` page.
- Payment intent: send sheet opens with the Bitrefill invoice (derived from code, not from a test).
- Buy: `BuyBitcoin` visible; button leaves the app to Safari.
- BTCPay: `BTCPayConnection` sheet; success toast `btcpay__success_title`, error toast `btcpay__error_title` (`BTCPayConnectionSheet.swift:119,129`).

## Not covered by tests
- No journey, e2e or BitkitUITests flow for any screen here.
- Unit tests only: `BitkitTests/ShopOriginTests.swift` (allowed hosts, message-sender origin, main-frame navigation limits, BTC Map allowed), `BitkitTests/ShopPaymentRequestTests.swift` (supported scan types, rejection of pubky signup/wrapped pubky requests without clearing send state), `BitkitTests/SamRockSetupRequestTests.swift` (URL parsing, descriptor shape, POST payload, response decoding).
- Untested in code: Map tab, intro gating, category list, blocked-navigation toast, BTCPay sheet UI states, `BuyBitcoinView`.

## Gotchas
- Shop is not behind `PaykitFeatureFlags`; the Paykit-only `Suggestion-profile` card is.
- `Tab-*` ids are English-only (`journeys/README.md`).
- Discover and `ShopMain` use `.offlineOverlay`; both load web content, so they need network.
- On the Map tab the outer scroll is disabled so the web view pans (`ShopDiscoverScrollModifier`).
- The Bitrefill message bridge is injected by `ShopOrigin.messageBridgeScript` after `didFinish`.
- Scanner scope `.paymentRequests` is used for embed messages; `ShopPaymentRequestTests` asserts pubky signup and wrapped pubky requests are rejected there, and `AppViewModel.swift:610` handles BTCPay setup only for scope `.unrestricted`.
