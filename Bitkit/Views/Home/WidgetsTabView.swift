import SwiftUI

struct WidgetsTabView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel
    @Binding var isEditingWidgets: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
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
            .padding(.top, windowSafeAreaInsets.top + 48)
            .padding(.horizontal)
            .padding(.bottom, 150) // Leave space for tab bar and dots
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func rowContent(_ row: WidgetsTabRow) -> some View {
        switch row {
        case .suggestions:
            if isEditingWidgets {
                SuggestionsEditRow()
            } else {
                Suggestions()
            }
        case let .widget(widget):
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

/// Collapsed suggestions row shown in edit mode. Matches widget edit layout with delete/edit disabled.
private struct SuggestionsEditRow: View {
    var body: some View {
        Button {} label: {
            HStack(spacing: 16) {
                Image("suggestions-widget")
                    .resizable()
                    .frame(width: 32, height: 32)

                BodyMSBText(t("cards__suggestions"))
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 8) {
                    Image("trash")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .frame(width: 32, height: 32)
                        .opacity(0.2)
                    Image("gear-six")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .frame(width: 32, height: 32)
                        .opacity(0.2)
                    Image("burger")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .overlay {
                            Color.clear
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .trackDragHandle()
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(WidgetButtonStyle())
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(16)
        .accessibilityIdentifier("SuggestionsWidget")
    }
}
