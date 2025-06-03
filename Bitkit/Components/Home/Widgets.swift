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

    @State private var isEditing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CaptionText(localizedString("widgets__widgets"))
                    .textCase(.uppercase)

                Spacer()

                Button(action: {
                    isEditing.toggle()
                }) {
                    Image(isEditing ? "checkmark" : "sort-ascending")
                        .resizable()
                        .foregroundColor(.textSecondary)
                        .frame(width: 24, height: 24)
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

            CustomButton(
                title: localizedString("widgets__add"), variant: .tertiary, size: .large, icon: Image("plus")
            ) {
                if app.hasSeenWidgetsIntro {
                    navigation.navigate(.widgetsList)
                } else {
                    navigation.navigate(.widgetsIntro)
                }
            }
            .padding(.top, 16)
        }
    }
}

#Preview {
    VStack {
        Widgets()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(WidgetsViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
