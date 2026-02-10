import SwiftUI

struct AddTagButton: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 6) {
                BodySSBText(t("wallet__tags_add_button"))
                    .lineLimit(1)

                Image("plus")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.textSecondary)
                    .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.textSecondary, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
            )
            .cornerRadius(8)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
        }
        .buttonStyle(.plain)
    }
}
