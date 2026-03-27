import SwiftUI

struct HomeWidgetsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var widgets: WidgetsViewModel
    @Binding var isEditingWidgets: Bool

    /// Widgets to display; suggestions widget is hidden when it would show no cards (unless editing).
    private var widgetsToShow: [Widget] {
        widgets.savedWidgets.filter { widget in
            if widget.type != .suggestions { return true }
            if isEditingWidgets { return true }
            return !Suggestions.visibleCards(wallet: wallet, app: app, settings: settings, suggestionsManager: suggestionsManager).isEmpty
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                DraggableList(
                    widgetsToShow,
                    id: \.id,
                    enableDrag: isEditingWidgets,
                    itemHeight: 80,
                    onReorder: { sourceIndex, destinationIndex in
                        widgets.reorderWidgets(from: sourceIndex, to: destinationIndex)
                    }
                ) { widget in
                    rowContent(widget)
                }
                .id(widgetsToShow.map(\.id))

                CustomButton(title: t("widgets__add"), variant: .tertiary) {
                    if app.hasSeenWidgetsIntro {
                        navigation.navigate(.widgetsList)
                    } else {
                        navigation.navigate(.widgetsIntro)
                    }
                }
                .padding(.top, 16)
                .accessibilityIdentifier("WidgetsAdd")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, ScreenLayout.topPaddingWithSafeArea)
            .padding(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
            .padding(.horizontal)
        }
    }

    private func rowContent(_ widget: Widget) -> some View {
        widget.view(
            widgetsViewModel: widgets,
            isEditing: isEditingWidgets,
            onEditingEnd: { withAnimation { isEditingWidgets = false } }
        )
    }
}
