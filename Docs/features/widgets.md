# Widgets (home widgets and iOS home-screen widgets)

Scope: in-app home widgets (add, edit options, resize, reorder, remove, intro, show/hide setting) for price, news, blocks, facts, weather, calculator, suggestions, and the WidgetKit extension `BitkitWidget` that shows five of them on the iOS home screen.

## What it does
- Widget types (`WidgetType` in `Bitkit/ViewModels/WidgetsViewModel.swift`): `price`, `news`, `blocks`, `facts`, `weather`, `calculator`, `suggestions`. One widget per type. Default set for new installs and reset: suggestions, price, blocks, facts, weather, calculator, news. Persisted as JSON under `UserDefaults` key `savedWidgets`.
- Sizes `small` (half width) / `wide`; defaults wide for price, news, suggestions, small for others. `suggestions` has no small size. Chosen with the carousel on the preview sheet.
- Options: price (pair, default `BTC/USD`; period `1D/1W/1M/1Y`), news (show title, source, date; title is locked on), blocks (fields height, time, date, transactionCount, size, fees), weather (one metric: `fiatFee`, `satsFee`, `nextBlockFee`). Facts, calculator, suggestions have no options. Edit items are built in `Bitkit/Views/Widgets/WidgetEditModels.swift`.
- Data sources: price `https://feeds.synonym.to/price-feed/api` (`PriceService`), news `.../news-feed/api/articles` (`NewsService`), blocks and weather `https://mempool.space/api` (`BlocksService`, `MempoolWeatherAPI`), facts are a local random list rotated every 2 minutes (`FactsViewModel`). URLs in `Bitkit/Constants/WidgetEnv.swift`.
- "Show Widgets" setting (`showWidgets`, default on): when off, the home widgets page disappears and the widget list sheet shows disabled tiles plus `WidgetEnableInSettings`.
- Home-screen widgets (`BitkitWidget/BitkitWidget.swift` bundle): `BitkitPriceWidget`, `BitkitNewsWidget`, `BitkitBlocksWidget`, `BitkitFactsWidget`, `BitkitWeatherWidget`; families `systemSmall`, `systemMedium`. No calculator or suggestions extension widget. In-app options are mirrored to the App Group `group.bitkit` by `*HomeScreenWidgetOptionsStore` (keys like `home_screen_price_widget_options_v1`) and trigger `WidgetCenter.reloadTimelines`. The news widget links to the article URL; `MainNavView` opens `http(s)` links in the browser (see `deeplinks.md`).

## How a user reaches it
- Home page 1 (swipe up from the wallet page, `HomeScrollView`) renders `HomeWidgetsView`. Or `HeaderMenu` -> `DrawerWidgets`: intro unseen -> `WidgetsIntroView` (id `WidgetsOnboarding`, buttons `WidgetsOnboardingViewOrganize` = mark seen and go to the widgets page (list sheet if Show Widgets is off), `WidgetsOnboardingAddWidget` = mark seen and open the list sheet); intro seen -> scroll to widgets page, or the list sheet when "Show Widgets" is off. Flag: `hasSeenWidgetsIntro`.
- Add: `WidgetsAdd` (below the fold; with intro unseen it opens the intro instead) -> sheet `.widgets` list, tiles `WidgetListItem-<type>` -> preview (`WidgetSave`, `WidgetEdit` for price/news/blocks/weather, `WidgetDelete` once saved) -> edit (`<key>_setting_row`, e.g. `BTC/EUR_setting_row`, `1W_setting_row`, `showSource_setting_row`; `WidgetEditReset`, `WidgetEditPreview`).
- Edit mode: header pencil `WidgetsEdit` (only on the widgets page; toggles to a check). In edit mode each card shows `<Name>_WidgetActionDelete`, `<Name>_WidgetActionEdit` (opens preview), `<Name>_WidgetActionReorder` (drag handle), where `<Name>` is the English widget name: `Bitcoin Price`, `Bitcoin Blocks`, `Bitcoin Headlines`, `Bitcoin Facts`, `Bitcoin Weather`, `Bitkit Suggestions`, `Bitcoin Calculator` (dynamic, from localisation). Delete asks a confirm alert (text `Yes, Delete`).
- Outside edit mode a card has id `<Type>Widget` (`PriceWidget`, `NewsWidget`, `BlocksWidget`, `FactsWidget`, `WeatherWidget`, `CalculatorWidget`, `SuggestionsWidget`). Price rows `PriceWidgetRow-<pair>`; calculator inputs `CalculatorBtcInput`, `CalculatorFiatInput`.
- Settings: `HeaderMenu` -> `DrawerSettings` -> `WidgetsSettings` -> `ShowWidgets`, `ResetWidgets`, `ResetSuggestions`, confirm `DialogConfirm` / `DialogCancel`.

## Code
- Views: `Bitkit/Views/Home/HomeWidgetsView.swift`, `Bitkit/Views/HomeScreen.swift`, `Bitkit/Views/Widgets/` (`WidgetsSheet` with `WidgetsRoute` `.list/.preview(type)/.edit(type)`, `WidgetsListSheetView`, `WidgetPreviewSheetView`, `WidgetEditSheetView`, `WidgetEditLogic`, `WidgetsIntroView`), `Bitkit/Components/Widgets/*` (cards, `BaseWidget` edit overlay, `Suggestions`), `Bitkit/Components/WidgetsOnboardingView.swift` (home hint, dismissed via `hasDismissedWidgetsOnboardingHint`), `Bitkit/Views/Settings/General/WidgetsSettingsScreen.swift`.
- State: `Bitkit/ViewModels/WidgetsViewModel.swift` (save/delete/reorder/clear, draft options), `Bitkit/ViewModels/Widgets/*ViewModel.swift`, `Bitkit/Services/Widgets/*`, `Bitkit/Models/{Price,News,Blocks,Weather}WidgetOptions.swift`, `Bitkit/Utilities/WidgetsBackupConverter.swift` (backup format, see `backup.md`).
- Sheet/route: `SheetID.widgets` (`SheetViewModel.showSheet(.widgets, data: WidgetsConfig(initialRoute:))`), `Route.widgetsIntro`, `Route.widgetsSettings`. Extension: `BitkitWidget/` (+ `BitkitWidget.entitlements`, App Group `group.bitkit`).

## How to drive it
- Journeys `journeys/widgets/`: `widgets-intro.xml` ("widgets intro", needs intro unseen: `xcrun simctl uninstall <device> to.bitkit` then rebuild), `add-widgets-flow.xml` ("add widgets flow", needs intro seen and "Show Widgets" on). README: `journeys/widgets/README.md`. No backend or funds needed.
- e2e `bitkit-e2e-tests/test/specs/widgets.e2e.ts`, describe `@widgets @ios_nightly`; helpers `bitkit-e2e-tests/test/helpers/widgets.ts`, `openHomeWidgets()` in `test/helpers/navigation.ts`. `beforeEach` reinstalls and onboards. No funds or docker.
  - `@widgets_1` add/edit/remove price (pair `BTC/EUR`, period `1W`, reset). `@widgets_2` add and remove blocks/news/facts/weather/calculator. `@widgets_3` settings: `ResetWidgets`, `ShowWidgets` off/on.
- Unit tests: `BitkitTests/WidgetsViewModelTests.swift`, `WidgetsViewModelReorderTests.swift`, `WidgetsViewModelDedupTests.swift`, `WidgetGridLayoutTests.swift`, `SavedWidgetDecodingTests.swift`, `WidgetsBackupConverterTests.swift`, `CalculatorWidgetTests.swift`, `NewsWidgetTitleTests.swift`, `WeatherConditionTests.swift`, `WeatherWidgetOptionsDecodingTests.swift`.

## What proves it
- Journeys: `WidgetsOnboarding` visible with "Hello, Widgets"; list sheet shows tiles; `WidgetSave` visible on the preview; after Save the home widgets page shows the new widget (journey: "Bitcoin Weather" last).
- e2e: `<Type>Widget` id displayed/absent (`expectWidgetPresent`), `<Name>_WidgetActionDelete` present in edit mode (`expectWidgetSavedInEditList`), `PriceWidgetRow-BTC/EUR` displayed after edit and gone after `WidgetEditReset`, `WidgetsEdit` visible/hidden for the Show Widgets toggle.

## Not covered by tests
- No journey/e2e for: resizing (small vs wide carousel), drag reorder (`Reorder` handle; unit-tested in `WidgetsViewModelReorderTests` only), news and blocks option editing, weather metric choice, deleting from the preview sheet (`WidgetDelete`), calculator keypad input, suggestions widget cards (see `home.md`), `WidgetsSettings` -> `ResetSuggestions` beyond `@settings_12`, widget data loading/failure states, `WidgetEnableInSettings` path (only described in the journeys README), widgets backup/restore (see `backup.md`).
- The `BitkitWidget` extension has no test of any kind (no journey, e2e or unit target found); simulator/device home-screen widget add flow is not in `journeys/README.md` capabilities.

## Gotchas
- `WidgetsAdd` sits below the fold: the journey and e2e (`scrollHomeToWidgets`) scroll first; `--identifier WidgetsAdd --predicate exists` passes without scrolling.
- Widget list tiles are `.onTapGesture` views with `.accessibilityElement(children: .combine)`; they have the button trait only when "Show Widgets" is on.
- `widgetActionId(widget, 'Drag')` in `test/helpers/widgets.ts` does not match the app id `..._WidgetActionReorder`; the helper is unused by the specs.
- `openWidgetsFeed` taps `WidgetsAdd` then `WidgetsOnboardingAddWidget` if shown; first use goes through the intro (`tapWidgetsIntroViewOrganizeIfShown`).
- The suggestions widget is hidden on the home page when it would show no cards, unless in edit mode (`HomeWidgetsView.widgetsToShow`).
- `@widgets_2` and `deleteAllDefaultWidgets` assume the default set above; changing `defaultSavedWidgets` breaks them. The e2e `DEFAULT_WIDGETS` order differs from the app's but is only used for deletion.
- Widget names in action ids and Delete confirm text are English; non-English devices break these ids.
