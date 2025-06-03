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
    @StateObject private var factsViewModel = FactsViewModel.shared
    @StateObject private var newsViewModel = NewsViewModel.shared
    @StateObject private var weatherViewModel = WeatherViewModel.shared

    // Widget data computed from the ID
    private var widget: (name: String, description: String, icon: String) {
        let name = localizedString("widgets__\(id.rawValue)__name")
        let fiatSymbol = currency.convert(sats: 1)?.symbol ?? "$"
        let description = localizedString("widgets__\(id.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        let icon = "\(id.rawValue)-widget"
        return (name: name, description: description, icon: icon)
    }

    private func getItems() -> [WidgetEditItem] {
        guard let editLogic = editLogic else { return [] }
        return WidgetEditItemFactory.getItems(
            for: id,
            blocksViewModel: blocksViewModel,
            factsViewModel: factsViewModel,
            newsViewModel: newsViewModel,
            weatherViewModel: weatherViewModel,
            blocksOptions: editLogic.blocksOptions,
            factsOptions: editLogic.factsOptions,
            newsOptions: editLogic.newsOptions,
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodyMText(
                localizedString("widgets__widget__edit_description", variables: ["name": widget.name]),
                textColor: .textSecondary
            )
            .padding(.vertical)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(getItems(), id: \.key) { item in
                        WidgetEditItemView(
                            item: item,
                            onToggle: { editLogic?.toggleOption(item) }
                        )
                        .accessibilityIdentifier("WidgetEditField-\(item.key)")
                    }
                }
                .id(refreshTrigger) // Force refresh when refreshTrigger changes
            }

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: localizedString("common__reset"),
                    variant: .secondary,
                    size: .large,
                    isDisabled: !(editLogic?.hasEdited ?? false),
                    shouldExpand: true
                ) {
                    onReset()
                }
                .accessibilityIdentifier("WidgetEditReset")

                CustomButton(
                    title: localizedString("common__preview"),
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
        .navigationTitle(localizedString("widgets__widget__edit"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
        .padding(.horizontal, 16)
        .onAppear {
            if editLogic == nil {
                let logic = WidgetEditLogic(widgetType: id, widgetsViewModel: widgets)
                logic.onStateChange = {
                    refreshTrigger.toggle()
                }
                editLogic = logic
            }
            editLogic?.loadCurrentOptions()
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
