import SwiftUI

struct WidgetEditItemView: View {
    let item: WidgetEditItem
    let onToggle: () -> Void

    var body: some View {
        let content = VStack(spacing: 0) {
            HStack(spacing: 16) {
                item.titleView
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let valueView = item.valueView {
                    valueView
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Image("checkmark")
                    .resizable()
                    .foregroundColor(item.isChecked ? .brandAccent : .gray3)
                    .frame(width: 32, height: 32)
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())

            Divider()
        }

        if item.type == .staticItem {
            content
        } else {
            Button(action: onToggle) {
                content
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}
