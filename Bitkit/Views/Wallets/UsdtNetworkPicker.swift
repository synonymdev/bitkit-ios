import SwiftUI

struct UsdtNetworkRow: View {
    let title: String
    let selected: Bool
    let identifier: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                Image("tether-circle").resizable().scaledToFit().frame(width: 40, height: 40)
                BodyMSBText(title)
                Spacer(minLength: 0)
                if selected {
                    Image("check-mark").resizable().scaledToFit().frame(width: 20, height: 20).foregroundColor(.usdtAccent)
                }
            }
            .padding(16).background(Color.gray6).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct UsdtNetworkPicker<Rows: View>: View {
    let note: String
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                rows()
                BodySText(note, textColor: .textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                UsdtCoinIllustration()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UsdtNetworkPicker")
    }
}
