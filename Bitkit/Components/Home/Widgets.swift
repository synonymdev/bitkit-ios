import SwiftUI

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
                    withAnimation {
                        isEditing.toggle()
                    }
                }) {
                    Image(isEditing ? "checkmark" : "sort-ascending")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.white)
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
                widget.view(isEditing: isEditing) {
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
