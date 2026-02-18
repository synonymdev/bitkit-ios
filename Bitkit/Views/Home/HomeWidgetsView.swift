import SwiftUI

struct HomeWidgetsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel
    @Binding var isEditingWidgets: Bool

    private var topPadding: CGFloat { windowSafeAreaInsets.top + 48 + 16 } // safe area + header + spacing
    private var bottomPadding: CGFloat { windowSafeAreaInsets.bottom + 64 + 32 } // safe area + tab bar + spacing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DraggableList(
                widgets.orderedRows,
                id: \.id,
                enableDrag: isEditingWidgets,
                itemHeight: 80,
                onReorder: { sourceIndex, destinationIndex in
                    widgets.reorderWidgetsTab(from: sourceIndex, to: destinationIndex)
                }
            ) { row in
                rowContent(row)
            }
            .id(widgets.orderedRows.map(\.id))

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

    @ViewBuilder
    private func rowContent(_ row: WidgetsTabRow) -> some View {
        if case let .widget(widget) = row {
            WidgetViewWrapper(widget: widget, isEditing: isEditingWidgets) {
                withAnimation {
                    isEditingWidgets = false
                }
            }
        }
    }
}

/// Wraps a widget and forwards view model + edit state to the widget's view builder.
private struct WidgetViewWrapper: View {
    let widget: Widget
    let isEditing: Bool
    let onEditingEnd: (() -> Void)?

    @EnvironmentObject private var widgets: WidgetsViewModel

    var body: some View {
        widget.view(widgetsViewModel: widgets, isEditing: isEditing, onEditingEnd: onEditingEnd)
    }
}
