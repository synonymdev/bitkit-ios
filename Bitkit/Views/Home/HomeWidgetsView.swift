import SwiftUI

struct HomeWidgetsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel
    @Binding var isEditingWidgets: Bool

    /// Safe area + header + spacing
    private var topPadding: CGFloat {
        windowSafeAreaInsets.top + 48 + 16
    }

    /// Safe area + tab bar + spacing
    private var bottomPadding: CGFloat {
        windowSafeAreaInsets.bottom + 64 + 32
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                DraggableList(
                    widgets.savedWidgets,
                    id: \.id,
                    enableDrag: isEditingWidgets,
                    itemHeight: 80,
                    onReorder: { sourceIndex, destinationIndex in
                        widgets.reorderWidgetsTab(from: sourceIndex, to: destinationIndex)
                    }
                ) { widget in
                    rowContent(widget)
                }
                .id(widgets.savedWidgets.map(\.id))

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
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
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
