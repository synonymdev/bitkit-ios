import SwiftUI

struct Widgets: View {
    @State private var widgets: [Widget] = [
        // TODO: Get saved widgets
        Widget(id: UUID(), type: .news),
        Widget(id: UUID(), type: .facts),
    ]
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
                widgets,
                id: \.id,
                enableDrag: isEditing,
                itemHeight: 80,
                onReorder: { sourceIndex, destinationIndex in
                    withAnimation {
                        let widget = widgets.remove(at: sourceIndex)
                        widgets.insert(widget, at: destinationIndex)
                    }
                }
            ) { widget in
                widget.view(isEditing: isEditing)
            }

            CustomButton(
                title: localizedString("widgets__add"), variant: .tertiary, size: .large, icon: Image("plus"), destination: SettingsListView()
            )
            .padding(.top, 16)
        }
    }
}

// Model for widgets
struct Widget: Identifiable {
    let id: UUID
    let type: WidgetType

    func view(isEditing: Bool) -> some View {
        switch type {
        case .block:
            // return AnyView(BlockWidget(isEditing: isEditing))
            break
        case .calculator:
            // return AnyView(CalculatorWidget(isEditing: isEditing))
            break
        case .facts:
            return AnyView(FactsWidget(isEditing: isEditing))
        case .news:
            return AnyView(NewsWidget(isEditing: isEditing))
        case .price:
            // return AnyView(PriceWidget(isEditing: isEditing))
            break
        case .weather:
            // return AnyView(WeatherWidget(isEditing: isEditing))
            break
        }

        return AnyView(FactsWidget(isEditing: isEditing))
    }
}

enum WidgetType {
    case block
    case calculator
    case facts
    case news
    case price
    case weather
}

#Preview {
    VStack {
        Widgets()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
