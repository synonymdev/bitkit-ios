import SwiftUI

struct WidgetListItem: View {
    let id: WidgetType
    let isDisabled: Bool

    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel

    init(id: WidgetType, isDisabled: Bool = false) {
        self.id = id
        self.isDisabled = isDisabled
    }

    // Widget data computed from the ID
    private var widget: (name: String, description: String, icon: String) {
        let name = t("widgets__\(id.rawValue)__name")

        // Get fiat symbol from currency conversion
        let fiatSymbol = currency.symbol
        let description = t("widgets__\(id.rawValue)__description", variables: ["fiatSymbol": fiatSymbol])
        let icon = "\(id.rawValue)-widget"

        return (name: name, description: description, icon: icon)
    }

    private func onPress() {
        if isDisabled {
            return
        }

        navigation.navigate(.widgetDetail(id))
    }

    var body: some View {
        Button(action: onPress) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Image(widget.icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.trailing, 16)

                    VStack(alignment: .leading, spacing: 0) {
                        BodyMSBText(widget.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        CaptionBText(widget.description, textColor: .textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.trailing, 20)

                    Image("chevron")
                        .resizable()
                        .foregroundColor(.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

                Divider()
                    .padding(.vertical, 16)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isDisabled ? 0.3 : 1)
        .accessibilityIdentifier("WidgetListItem-\(id.rawValue)")
    }
}

#Preview {
    VStack(spacing: 16) {
        WidgetListItem(id: .price)
        WidgetListItem(id: .news)
        WidgetListItem(id: .facts)
    }
    .padding()
    .background(Color.black)
    .environmentObject(NavigationViewModel())
    .environmentObject(CurrencyViewModel())
    .preferredColorScheme(.dark)
}
