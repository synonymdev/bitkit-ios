import SwiftUI

/// Preview screen for the Calculator widget.
struct CalculatorWidgetPreviewView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel
    @EnvironmentObject private var currency: CurrencyViewModel

    // TODO: revert to 0 to re-enable the compact widget preview
    @State private var carouselPage: Int = 1
    @State private var previewActiveInput: CalculatorMoneyType?
    @State private var showDeleteAlert = false
    @State private var values = CalculatorWidgetValues()

    private let widgetType: WidgetType = .calculator

    private var widgetName: String {
        t("widgets__calculator__name")
    }

    private var widgetDescription: String {
        t("widgets__calculator__description", variables: ["fiatSymbol": currency.symbol])
    }

    private var isWidgetSaved: Bool {
        widgets.isWidgetSaved(widgetType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationBar(title: widgetName, showMenuButton: false)

            BodyMText(widgetDescription, textColor: .textSecondary)

            VStack(spacing: 16) {
                carousel

                // Size label hidden while only the wide widget is shown
                // sizeLabel

                // Page indicator hidden while only the wide widget is shown
                // pageIndicator
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            buttonsRow
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .task {
            hydrateValues()
        }
        .onChange(of: currency.selectedCurrency) {
            hydrateValues()
        }
        .onChange(of: currency.displayUnit) {
            hydrateValues()
        }
        .onChange(of: currency.rates) {
            hydrateValues()
        }
        .onDisappear {
            previewActiveInput = nil
        }
        .alert(
            t("widgets__delete__title"),
            isPresented: $showDeleteAlert,
            actions: {
                Button(t("common__cancel"), role: .cancel) { showDeleteAlert = false }
                Button(t("common__delete_yes"), role: .destructive) { onDelete() }
            },
            message: {
                Text(t("widgets__delete__description", variables: ["name": widgetName]))
            }
        )
    }

    private var carousel: some View {
        TabView(selection: $carouselPage) {
            // Compact preview temporarily hidden — only the wide widget can be added for now
            // compactPage.tag(0)
            widePage.tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
    }

    private var compactPage: some View {
        VStack {
            Spacer(minLength: 0)
            CalculatorWidgetCompactContent(values: values)
                .frame(width: 163, height: 192)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var widePage: some View {
        VStack {
            Spacer(minLength: 0)
            CalculatorWidgetWideContent(
                values: values,
                activeInput: previewActiveInput,
                onSelectInput: selectInput
            )
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(16)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var sizeLabel: some View {
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

    private var pageIndicator: some View {
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

    private func hydrateValues() {
        let saved = CalculatorWidgetOptionsStore.load()
        let bitcoinValue = Self.previewBitcoinValue(saved: saved, displayUnit: currency.displayUnit)

        values = CalculatorWidgetValues(
            bitcoinValue: bitcoinValue,
            fiatValue: Self.previewFiatValue(saved: saved, recalculatedFiatValue: fiatValue(for: bitcoinValue)),
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
    }

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

    private func fiatValue(for bitcoinValue: String) -> String {
        guard !bitcoinValue.isEmpty else { return "" }
        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(bitcoinValue, displayUnit: currency.displayUnit)
        if sats == 0 { return "0.00" }
        guard let converted = currency.convert(sats: sats) else {
            return ""
        }
        return CalculatorWidgetFormatter.fiatRawValue(from: converted.value)
    }

    private func selectInput(_ input: CalculatorMoneyType) {
        previewActiveInput = input
    }

    private func onSave() {
        widgets.saveWidget(widgetType)
        navigation.reset()
    }

    private func onDelete() {
        widgets.deleteWidget(widgetType)
        navigation.reset()
    }
}

#Preview {
    NavigationStack {
        CalculatorWidgetPreviewView()
            .environmentObject(NavigationViewModel())
            .environmentObject(WidgetsViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
