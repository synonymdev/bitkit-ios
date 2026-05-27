import SwiftUI

/// Sheet-shell wrapper around the existing `WidgetEditLogic` + `WidgetEditItemView` flow.
/// Header swaps the full-screen `NavigationBar` for a `SheetHeader` and the "Preview"
/// button pops back to the preview route inside the same sheet navigation stack.
struct WidgetEditSheetView: View {
    let type: WidgetType
    @Binding var navigationPath: [WidgetsRoute]

    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var widgets: WidgetsViewModel

    @State private var editLogic: WidgetEditLogic?
    @State private var refreshTrigger = false

    @StateObject private var blocksViewModel = BlocksViewModel.shared
    @StateObject private var newsViewModel = NewsViewModel.shared
    @StateObject private var priceViewModel = PriceViewModel.shared
    @StateObject private var weatherViewModel = WeatherViewModel.shared

    private var widgetName: String {
        t("widgets__\(type.rawValue)__name")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: widgetName, showBackButton: true)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.key) { item in
                        WidgetEditItemView(
                            item: item,
                            onToggle: { editLogic?.toggleOption(item) }
                        )
                        .accessibilityIdentifier("\(item.key)_setting_row")
                    }
                }
                .id(refreshTrigger)
            }

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__reset"),
                    variant: .secondary,
                    size: .large,
                    isDisabled: !(editLogic?.hasEdited ?? false),
                    shouldExpand: true,
                    action: onReset
                )
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
                let logic = WidgetEditLogic(widgetType: type, widgetsViewModel: widgets)
                logic.onStateChange = { refreshTrigger.toggle() }
                editLogic = logic
            }
            editLogic?.loadCurrentOptions()

            if type == .price {
                priceViewModel.fetchForEditView()
            }
        }
    }

    private var items: [WidgetEditItem] {
        guard let editLogic else { return [] }
        return WidgetEditItemFactory.getItems(
            for: type,
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
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    private func onReset() {
        editLogic?.resetOptions()
    }
}
