import SwiftUI

struct WidgetViewWrapper: View {
    let widget: Widget
    let isEditing: Bool
    let onEditingEnd: (() -> Void)?

    @EnvironmentObject private var widgets: WidgetsViewModel

    var body: some View {
        widget.view(widgetsViewModel: widgets, isEditing: isEditing, onEditingEnd: onEditingEnd)
    }
}

struct Widgets: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    @Binding var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CaptionMText(t("widgets__widgets"))

                Spacer()

                Button(action: {
                    isEditing.toggle()
                }) {
                    Image(isEditing ? "checkmark" : "sort-ascending")
                        .resizable()
                        .foregroundColor(.textSecondary)
                        .frame(width: 24, height: 24)
                        .accessibilityIdentifier("WidgetsEdit")
                }
            }
            .padding(.bottom, 16)

            DraggableList(
                widgets.savedWidgets,
                id: \.id,
                enableDrag: isEditing,
                itemHeight: 80,
                onReorder: { sourceIndex, destinationIndex in
                    withAnimation {
                        widgets.reorderWidgets(from: sourceIndex, to: destinationIndex)
                    }
                }
            ) { widget in
                WidgetViewWrapper(widget: widget, isEditing: isEditing) {
                    withAnimation {
                        isEditing = false
                    }
                }
            }

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
    }
}

#Preview {
    VStack {
        Widgets(isEditing: .constant(false))
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(WidgetsViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
