import SwiftUI

struct WidgetEditItemView: View {
    let item: WidgetEditItem
    let onToggle: () -> Void

    var body: some View {
        switch item.type {
        case .sectionHeader:
            item.titleView
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
        case .staticItem:
            row
        case .toggleItem:
            Button(action: onToggle) {
                row
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var row: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                item.titleView
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let valueView = item.valueView {
                    valueView
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if item.type != .staticItem {
                    Image("check-mark")
                        .resizable()
                        .foregroundColor(item.isChecked ? .brandAccent : .white32)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())

            Divider()
        }
    }
}
