# Widget journeys

Cover the widgets intro (first run) and the add-widget flow reached from the wallet home screen.

## Preconditions
- Onboarded dev wallet. No backend or funding is required — widget feeds are read-only.
- **Widgets must be enabled** in Settings → Widgets ("Show Widgets"). When it is off the widget tiles
  in the list sheet render disabled and an "Enable in settings" button (id `WidgetEnableInSettings`)
  is shown instead, and both journeys fail on the first tap.
- `widgets-intro.xml` needs the intro **unseen** and `add-widgets-flow.xml` needs it **seen**. The
  flag is `hasSeenWidgetsIntro` in `UserDefaults`; reset it by reinstalling the app
  (`xcodebuildmcp simulator install` over a fresh wallet) or by wiping the simulator's app data.

## iOS notes
- The drawer menu row is `DrawerWidgets`. With the intro unseen it pushes the intro screen
  (id `WidgetsOnboarding`); with the intro seen it opens the home widgets page or the widgets list
  sheet, depending on the "Show Widgets" setting.
- Every widget tile routes to the **preview** screen, whether or not the widget has editable options,
  so "Save Widget" (id `WidgetSave`) is reachable in one tap from the list for all types.

## Verified on simulator

Both journeys were walked on an iPhone 17 simulator with no backend running:

- The drawer row, the intro screen and its two buttons, the sheet, all six tiles, the preview screen
  and Save Widget all resolve, and Save returns to the widgets page with the new widget present.
- **`WidgetsAdd` sits below the fold** on the home widgets page — the journey has to scroll before it
  can be tapped, even though `--identifier WidgetsAdd --predicate exists` passes without scrolling.
- All six tiles fit on an iPhone 17 sheet without scrolling, so that step is conditional.
- Widget tiles are `.onTapGesture` views, not buttons. They now carry
  `.accessibilityElement(children: .combine)` + `.accessibilityAddTraits(.isButton)` so each is a
  single tappable target in the runtime snapshot; without `.combine` the identifier fanned out to
  every child label and made identifier-based tapping ambiguous.

## Identifiers used
- Drawer: `DrawerWidgets`.
- Intro: screen `WidgetsOnboarding`, buttons `WidgetsOnboardingViewOrganize` and
  `WidgetsOnboardingAddWidget`.
- Home widgets section: `WidgetsAdd`, edit mode `WidgetsEdit`.
- List sheet: tiles `WidgetListItem-<type>` where type is one of `price`, `news`, `blocks`, `facts`,
  `weather`, `calculator`, `suggestions`; disabled-state button `WidgetEnableInSettings`.
- Preview: `WidgetSave`.
