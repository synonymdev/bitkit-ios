import SwiftUI

/// Preview screen for the Calculator widget.
struct CalculatorWidgetPreviewView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel
    @EnvironmentObject private var currency: CurrencyViewModel

    @State private var carouselPage: Int = 0
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

                sizeLabel

                pageIndicator
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
            compactPage.tag(0)
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
            CalculatorWidgetWideContent(values: values)
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
        let saved = CalculatorHomeScreenWidgetOptionsStore.load()
        let savedSats = CalculatorWidgetFormatter.bitcoinValueToSats(saved.bitcoinValue, displayUnit: saved.displayUnit)
        let bitcoinValue = saved.bitcoinValue.isEmpty
            ? CalculatorWidgetValues().bitcoinValue
            : CalculatorWidgetFormatter.satsToBitcoinValue(savedSats, displayUnit: currency.displayUnit)

        values = CalculatorWidgetValues(
            bitcoinValue: bitcoinValue,
            fiatValue: fiatValue(for: bitcoinValue),
            displayUnit: currency.displayUnit,
            currencySymbol: currency.symbol,
            selectedCurrency: currency.selectedCurrency
        )
    }

    private func fiatValue(for bitcoinValue: String) -> String {
        let sats = CalculatorWidgetFormatter.bitcoinValueToSats(bitcoinValue, displayUnit: currency.displayUnit)
        if sats == 0 { return "0.00" }
        guard let converted = currency.convert(sats: sats) else {
            return CalculatorHomeScreenWidgetOptionsStore.load().fiatValue
        }
        return CalculatorWidgetFormatter.fiatRawValue(from: converted.value)
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
