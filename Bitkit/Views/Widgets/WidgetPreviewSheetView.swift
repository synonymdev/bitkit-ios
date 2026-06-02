import SwiftUI

/// Unified preview screen for every widget type.
/// User picks `small` vs `wide` via the carousel; tapping "Save Widget" persists the chosen size.
struct WidgetPreviewSheetView: View {
    let type: WidgetType
    @Binding var navigationPath: [WidgetsRoute]

    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel

    @State private var carouselPage: Int
    @State private var showDeleteAlert = false

    init(type: WidgetType, navigationPath: Binding<[WidgetsRoute]>) {
        self.type = type
        _navigationPath = navigationPath
        _carouselPage = State(initialValue: Self.initialCarouselPage(for: type, widgets: nil))
    }

    /// Picks the page index that matches the widget's currently-saved size (or `.small` if new).
    /// Called from `task` once the environment is available.
    private static func initialCarouselPage(for type: WidgetType, widgets: WidgetsViewModel?) -> Int {
        guard let widgets, widgets.isWidgetSaved(type) else { return 0 }
        return widgets.getSize(for: type) == .wide ? 1 : 0
    }

    private var metadata: WidgetMetadata {
        WidgetMetadata(type: type, fiatSymbol: currency.symbol)
    }

    private var hasSettings: Bool {
        switch type {
        case .price, .news, .blocks, .weather: return true
        case .facts, .calculator, .suggestions: return false
        }
    }

    private var supportsSmall: Bool {
        type != .suggestions
    }

    private var isWidgetSaved: Bool {
        widgets.isWidgetSaved(type)
    }

    private var hasCustomOptions: Bool {
        widgets.hasCustomOptions(for: type)
    }

    private var chosenSize: WidgetSize {
        carouselPage == 0 && supportsSmall ? .small : .wide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: metadata.name, showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                BodyMText(metadata.description, textColor: .textSecondary)
                    .padding(.bottom, 16)

                Divider().background(Color.white.opacity(0.1))

                if hasSettings {
                    settingsRow
                    Divider().background(Color.white.opacity(0.1))
                }
            }

            VStack(spacing: 16) {
                carousel
                sizeLabel
                pageIndicator
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            buttonsRow
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pushed navigationDestination views get an opaque system background; override it
        // with the sheet's gray7 so preview matches the list route.
        .background(Color.gray7)
        .task {
            if supportsSmall {
                carouselPage = Self.initialCarouselPage(for: type, widgets: widgets)
            }
        }
        .alert(
            t("widgets__delete__title"),
            isPresented: $showDeleteAlert,
            actions: {
                Button(t("common__cancel"), role: .cancel) { showDeleteAlert = false }
                Button(t("common__delete_yes"), role: .destructive) { onDelete() }
            },
            message: {
                Text(t("widgets__delete__description", variables: ["name": metadata.name]))
            }
        )
    }

    // MARK: - Settings cell

    private var settingsRow: some View {
        Button {
            navigationPath.append(.edit(type))
        } label: {
            HStack(alignment: .center, spacing: 0) {
                BodyMText(t("widgets__widget__settings"), textColor: .textPrimary)

                Spacer()

                BodyMText(
                    hasCustomOptions
                        ? t("widgets__widget__edit_custom")
                        : t("widgets__widget__edit_default"),
                    textColor: .textSecondary
                )

                Image("chevron")
                    .resizable()
                    .foregroundColor(.textSecondary)
                    .frame(width: 24, height: 24)
                    .padding(.leading, 5)
            }
            .frame(maxWidth: .infinity, minHeight: 51)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("WidgetEdit")
    }

    // MARK: - Carousel

    private var carousel: some View {
        TabView(selection: $carouselPage) {
            if supportsSmall {
                smallPage.tag(0)
            }
            widePage.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
        .padding(.horizontal, -16)
    }

    private var smallPage: some View {
        VStack {
            Spacer(minLength: 0)
            smallContent
                .frame(width: 163, height: 192)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var widePage: some View {
        VStack {
            Spacer(minLength: 0)
            wideContent
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var smallContent: some View {
        switch type {
        case .price: PriceSmallPreview()
        case .news: NewsSmallPreview()
        case .blocks: BlocksSmallPreview()
        case .weather: WeatherSmallPreview()
        case .facts: FactsSmallPreview()
        case .calculator: CalculatorSmallPreview()
        case .suggestions: EmptyView()
        }
    }

    @ViewBuilder
    private var wideContent: some View {
        switch type {
        case .price: PriceWidePreview()
        case .news: NewsWidePreview()
        case .blocks: BlocksWidePreview()
        case .weather: WeatherWidePreview()
        case .facts: FactsWidePreview()
        case .calculator: CalculatorWidePreview()
        case .suggestions: SuggestionsWidePreview()
        }
    }

    // MARK: - Size label & page indicator

    @ViewBuilder
    private var sizeLabel: some View {
        if supportsSmall {
            HStack {
                Spacer()
                CaptionMText(
                    carouselPage == 0
                        ? t("widgets__widget__size_small")
                        : t("widgets__widget__size_wide"),
                    textColor: .textSecondary
                )
                .textCase(.uppercase)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if supportsSmall {
            HStack(spacing: 8) {
                Spacer()
                ForEach(0 ..< 2, id: \.self) { index in
                    Circle()
                        .fill(carouselPage == index ? Color.white : Color.white.opacity(0.32))
                        .frame(width: 8, height: 8)
                }
                Spacer()
            }
        }
    }

    // MARK: - Buttons

    private var buttonsRow: some View {
        HStack(spacing: 16) {
            if isWidgetSaved {
                CustomButton(
                    title: t("common__delete"),
                    variant: .secondary,
                    size: .large,
                    shouldExpand: true
                ) {
                    showDeleteAlert = true
                }
                .accessibilityIdentifier("WidgetDelete")
            }

            CustomButton(
                title: t("widgets__widget__save_widget"),
                variant: .primary,
                size: .large,
                shouldExpand: true,
                action: onSave
            )
            .accessibilityIdentifier("WidgetSave")
        }
    }

    // MARK: - Actions

    private func onSave() {
        widgets.saveWidget(type, size: chosenSize)
        sheets.hideSheet()
    }

    private func onDelete() {
        widgets.deleteWidget(type)
        sheets.hideSheet()
    }
}

// MARK: - Per-type preview pages

//
// Each owns its singleton view-model observation and applies the standard card chrome
// (gray6 background, 16pt corner radius, 16pt padding).

private struct PriceSmallPreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @StateObject private var viewModel = PriceViewModel.shared

    private var options: PriceWidgetOptions {
        widgets.getOptions(for: .price, as: PriceWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = primary {
                PriceWidgetCompactContent(data: data, period: options.selectedPeriod)
                    .widgetCardChrome()
            } else {
                Color.gray6
                    .cornerRadius(16)
                    .overlay(ProgressView())
            }
        }
        .task(id: options) {
            viewModel.fetchPriceData(pairs: [options.selectedPair], period: options.selectedPeriod)
        }
    }

    private var primary: PriceData? {
        let data = viewModel.getCurrentData(for: options.selectedPeriod)
        return data.first(where: { $0.name == options.selectedPair }) ?? data.first
    }
}

private struct PriceWidePreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @StateObject private var viewModel = PriceViewModel.shared

    private var options: PriceWidgetOptions {
        widgets.getOptions(for: .price, as: PriceWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = primary {
                PriceWidgetWideContent(data: data, period: options.selectedPeriod)
                    .widgetCardChrome()
            } else {
                Color.gray6
                    .cornerRadius(16)
                    .frame(height: 152)
                    .overlay(ProgressView())
            }
        }
        .task(id: options) {
            viewModel.fetchPriceData(pairs: [options.selectedPair], period: options.selectedPeriod)
        }
    }

    private var primary: PriceData? {
        let data = viewModel.getCurrentData(for: options.selectedPeriod)
        return data.first(where: { $0.name == options.selectedPair }) ?? data.first
    }
}

private struct NewsSmallPreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @StateObject private var viewModel = NewsViewModel.shared

    private var options: NewsWidgetOptions {
        widgets.getOptions(for: .news, as: NewsWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = viewModel.widgetData {
                NewsWidgetCompactContent(title: data.title, timeAgo: data.timeAgo, options: options)
                    .widgetCardChrome()
            } else {
                Color.gray6
                    .cornerRadius(16)
                    .overlay(ProgressView())
            }
        }
        .task { viewModel.startUpdates() }
    }
}

private struct NewsWidePreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @StateObject private var viewModel = NewsViewModel.shared

    private var options: NewsWidgetOptions {
        widgets.getOptions(for: .news, as: NewsWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = viewModel.widgetData {
                NewsWidgetWideContent(title: data.title, publisher: data.publisher, timeAgo: data.timeAgo, options: options)
                    .frame(height: NewsWidgetWideContent.inAppContentHeight)
                    .widgetCardChrome()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: NewsWidgetWideContent.inAppContentHeight)
                    .widgetCardChrome()
            }
        }
        .task { viewModel.startUpdates() }
    }
}

private struct BlocksSmallPreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @StateObject private var viewModel = BlocksViewModel.shared

    private var options: BlocksWidgetOptions {
        widgets.getOptions(for: .blocks, as: BlocksWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = viewModel.blockData {
                BlocksWidgetCompactContent(data: data, options: options)
                    .widgetCardChrome()
            } else {
                Color.gray6
                    .cornerRadius(16)
                    .overlay(ProgressView())
            }
        }
        .task { viewModel.startUpdates() }
    }
}

private struct BlocksWidePreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @StateObject private var viewModel = BlocksViewModel.shared

    private var options: BlocksWidgetOptions {
        widgets.getOptions(for: .blocks, as: BlocksWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = viewModel.blockData {
                BlocksWidgetWideContent(data: data, options: options)
                    .frame(height: BlocksWidgetWideContent.inAppContentHeight)
                    .widgetCardChrome()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: BlocksWidgetWideContent.inAppContentHeight)
                    .widgetCardChrome()
            }
        }
        .task { viewModel.startUpdates() }
    }
}

private struct WeatherSmallPreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @StateObject private var viewModel = WeatherViewModel.shared

    private var options: WeatherWidgetOptions {
        widgets.getOptions(for: .weather, as: WeatherWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = viewModel.weatherData {
                WeatherWidgetCompactContent(
                    data: data,
                    metric: options.selectedMetric,
                    conditionTitle: t(data.condition.titleKey),
                    metricLabel: t(options.selectedMetric.labelKey)
                )
                .widgetCardChrome()
            } else {
                Color.gray6
                    .cornerRadius(16)
                    .overlay(ProgressView())
            }
        }
        .task {
            viewModel.setCurrencyViewModel(currency)
            viewModel.startUpdates()
        }
    }
}

private struct WeatherWidePreview: View {
    @EnvironmentObject private var widgets: WidgetsViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @StateObject private var viewModel = WeatherViewModel.shared

    private var options: WeatherWidgetOptions {
        widgets.getOptions(for: .weather, as: WeatherWidgetOptions.self)
    }

    var body: some View {
        Group {
            if let data = viewModel.weatherData {
                WeatherWidgetWideContent(
                    data: data,
                    metric: options.selectedMetric,
                    conditionTitle: t(data.condition.titleKey),
                    conditionDescription: t(data.condition.descriptionKey),
                    metricLabel: t(options.selectedMetric.labelKey)
                )
                .widgetCardChrome()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .widgetCardChrome()
            }
        }
        .task {
            viewModel.setCurrencyViewModel(currency)
            viewModel.startUpdates()
        }
    }
}

private struct FactsSmallPreview: View {
    @StateObject private var viewModel = FactsViewModel.shared

    var body: some View {
        FactsWidgetCompactContent(fact: viewModel.fact)
            .widgetCardChrome()
    }
}

private struct FactsWidePreview: View {
    @StateObject private var viewModel = FactsViewModel.shared

    var body: some View {
        FactsWidgetWideContent(fact: viewModel.fact)
            .widgetCardChrome()
            .frame(maxWidth: .infinity)
    }
}

private struct CalculatorWidePreview: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    @State private var previewActiveInput: CalculatorMoneyType?
    @State private var values = CalculatorWidgetValues()

    var body: some View {
        CalculatorWidgetWideContent(
            values: values,
            activeInput: previewActiveInput,
            onSelectInput: { input in previewActiveInput = input }
        )
        .widgetCardChrome()
        .frame(maxWidth: .infinity)
        .task { hydrate() }
        .onChange(of: currency.selectedCurrency) { hydrate() }
        .onChange(of: currency.displayUnit) { hydrate() }
        .onChange(of: currency.rates) { hydrate() }
        .onDisappear { previewActiveInput = nil }
    }

    private func hydrate() {
        let saved = CalculatorWidgetOptionsStore.load()
        let bitcoinValue = CalculatorWidgetPreviewLogic.previewBitcoinValue(saved: saved, displayUnit: currency.displayUnit)

        values = CalculatorWidgetValues(
            bitcoinValue: bitcoinValue,
            fiatValue: CalculatorWidgetPreviewLogic.previewFiatValue(saved: saved, recalculatedFiatValue: fiatValue(for: bitcoinValue)),
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
    }

    private func fiatValue(for bitcoinValue: String) -> String {
        guard !bitcoinValue.isEmpty else { return "" }
        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(bitcoinValue, displayUnit: currency.displayUnit)
        if sats == 0 { return "0.00" }
        guard let converted = currency.convert(sats: sats) else { return "" }
        return CalculatorWidgetFormatter.fiatRawValue(from: converted.value)
    }
}

enum CalculatorWidgetPreviewLogic {
    static func previewBitcoinValue(saved: CalculatorWidgetValues, displayUnit: BitcoinDisplayUnit) -> String {
        guard !saved.bitcoinValue.isEmpty else { return "" }

        let savedSats = CalculatorWidgetFormatter.bitcoinValueToSats(saved.bitcoinValue, displayUnit: saved.displayUnit)
        return savedSats == 0
            ? "0"
            : CalculatorWidgetFormatter.satsToBitcoinValue(savedSats, displayUnit: displayUnit)
    }

    static func previewFiatValue(saved: CalculatorWidgetValues, recalculatedFiatValue: String) -> String {
        saved.shouldRefreshBitcoinFromFiat ? saved.fiatValue : recalculatedFiatValue
    }
}

private struct CalculatorSmallPreview: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    @State private var values = CalculatorWidgetValues()

    var body: some View {
        // Display-only (no `onSelectInput`) — the preview carousel doesn't host the keypad.
        CalculatorWidgetCompactContent(values: values)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color.gray6)
            .cornerRadius(16)
            .task { hydrate() }
            .onChange(of: currency.selectedCurrency) { hydrate() }
            .onChange(of: currency.displayUnit) { hydrate() }
            .onChange(of: currency.rates) { hydrate() }
    }

    private func hydrate() {
        let saved = CalculatorWidgetOptionsStore.load()
        let bitcoinValue = CalculatorWidgetPreviewLogic.previewBitcoinValue(saved: saved, displayUnit: currency.displayUnit)

        values = CalculatorWidgetValues(
            bitcoinValue: bitcoinValue,
            fiatValue: CalculatorWidgetPreviewLogic.previewFiatValue(saved: saved, recalculatedFiatValue: fiatValue(for: bitcoinValue)),
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
    }

    private func fiatValue(for bitcoinValue: String) -> String {
        guard !bitcoinValue.isEmpty else { return "" }
        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(bitcoinValue, displayUnit: currency.displayUnit)
        if sats == 0 { return "0.00" }
        guard let converted = currency.convert(sats: sats) else { return "" }
        return CalculatorWidgetFormatter.fiatRawValue(from: converted.value)
    }
}

private struct SuggestionsWidePreview: View {
    var body: some View {
        Suggestions(isPreview: true, previewCardIds: Suggestions.previewSheetCardIds)
            .frame(maxWidth: .infinity)
    }
}

private extension View {
    func widgetCardChrome() -> some View {
        padding(16)
            .background(Color.gray6)
            .cornerRadius(16)
    }
}
