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
        case .toggleItem, .radioItem:
            Button(action: onToggle) {
                row
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var row: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                item.titleView
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let valueView = item.valueView {
                    valueView
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                accessoryView
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())

            CustomDivider()
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch item.type {
        case .toggleItem:
            Image("check-mark")
                .resizable()
                .foregroundColor(item.isChecked ? .brandAccent : .gray3)
                .frame(width: 32, height: 32)
        case .radioItem:
            if item.isChecked {
                Image("check-mark")
                    .resizable()
                    .foregroundColor(.brandAccent)
                    .frame(width: 32, height: 32)
            } else {
                Color.clear
                    .frame(width: 32, height: 32)
            }
        case .staticItem, .sectionHeader:
            EmptyView()
        }
    }
}
