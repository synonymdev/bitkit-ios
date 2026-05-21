import SwiftUI

// MARK: - Widget Edit View

struct WidgetEditView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel

    let id: WidgetType

    // Logic handler
    @State private var editLogic: WidgetEditLogic?
    @State private var refreshTrigger = false

    // View models for getting actual content
    @StateObject private var blocksViewModel = BlocksViewModel.shared
    @StateObject private var newsViewModel = NewsViewModel.shared
    @StateObject private var priceViewModel = PriceViewModel.shared
    @StateObject private var weatherViewModel = WeatherViewModel.shared

    /// Widget data computed from the ID
    private var widget: (name: String, description: String, icon: String) {
        let name = t("widgets__\(id.rawValue)__name")
        let fiatSymbol = currency.symbol
        let description = t("widgets__\(id.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        let icon = "\(id.rawValue)-widget"
        return (name: name, description: description, icon: icon)
    }

    private func getItems() -> [WidgetEditItem] {
        guard let editLogic else { return [] }
        return WidgetEditItemFactory.getItems(
            for: id,
            blocksViewModel: blocksViewModel,
            newsViewModel: newsViewModel,
            priceDataByPeriod: priceViewModel.dataByPeriod,
            weatherViewModel: weatherViewModel,
            blocksOptions: editLogic.blocksOptions,
            newsOptions: editLogic.newsOptions,
            priceOptions: editLogic.priceOptions,
            weatherOptions: editLogic.weatherOptions
        )
    }

    private func onPreview() {
        editLogic?.saveOptions()
        navigation.navigateBack()
    }

    private func onReset() {
        editLogic?.resetOptions()
    }

    /// v61 widget configuration screens (Price, News, Blocks, Weather) use the widget name as the title
    /// and skip the legacy description block.
    private var usesV61Header: Bool {
        id == .price || id == .blocks || id == .weather
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: usesV61Header ? widget.name : t("widgets__widget__edit"),
                showMenuButton: !usesV61Header
            )
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(getItems(), id: \.key) { item in
                        WidgetEditItemView(
                            item: item,
                            onToggle: { editLogic?.toggleOption(item) }
                        )
                        .accessibilityIdentifier("\(item.key)_setting_row")
                    }
                }
                .id(refreshTrigger) // Force refresh when refreshTrigger changes
            }

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__reset"),
                    variant: .secondary,
                    size: .large,
                    isDisabled: !(editLogic?.hasEdited ?? false),
                    shouldExpand: true
                ) {
                    onReset()
                }
                .accessibilityIdentifier("WidgetEditReset")

                CustomButton(
                    title: t("common__preview"),
                    variant: .primary,
                    size: .large,
                    isDisabled: !(editLogic?.hasEnabledOption ?? false),
                    shouldExpand: true,
                    action: onPreview
                )
                .accessibilityIdentifier("WidgetEditPreview")
            }
            .padding(.top, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if editLogic == nil {
                let logic = WidgetEditLogic(widgetType: id, widgetsViewModel: widgets)
                logic.onStateChange = {
                    refreshTrigger.toggle()
                }
                editLogic = logic
            }
            editLogic?.loadCurrentOptions()

            if id == .price {
                priceViewModel.fetchForEditView()
            }
        }
    }
}

#Preview {
    NavigationStack {
        WidgetEditView(id: .news)
            .environmentObject(NavigationViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(WidgetsViewModel())
    }
    .preferredColorScheme(.dark)
}
