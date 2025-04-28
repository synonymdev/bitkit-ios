import SwiftUI

enum TagIconType {
    case close
    case trash
}

struct Tag: View {
    let value: String
    let icon: TagIconType
    let onPress: (() -> Void)?
    let onDelete: (() -> Void)?

    init(
        _ value: String,
        icon: TagIconType = .close,
        onPress: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.value = value
        self.icon = icon
        self.onPress = onPress
        self.onDelete = onDelete
    }

    @ViewBuilder
    private var tagContent: some View {
        HStack(spacing: 0) { // Set spacing to 0 to precisely control with padding
            Text(value)
                .lineLimit(1)

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: icon == .close ? "xmark" : "trash")
                        .font(.caption.weight(.light)) // Adjust size if needed
                        .frame(width: 16, height: 16)
                }
                .padding(.leading, 8) // Corresponds to icon paddingLeft
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .foregroundColor(.white)
        .font(.body.weight(.bold))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white16, lineWidth: 2)
        )
        .cornerRadius(8)
        .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        if let onPress = onPress {
            Button(action: onPress) {
                tagContent
            }
            .buttonStyle(.plain) // Use plain button style to avoid default button appearance interfering
        } else {
            tagContent
        }
    }
}

#Preview {
    VStack(spacing: 10) {
        Tag("Lunch", icon: .close, onDelete: { print("Delete Lunch") })
        Tag("Dinner", icon: .trash, onDelete: { print("Delete Dinner") })
        Tag("Tappable", onPress: { print("Tapped") })
        Tag("Tappable & Deletable", icon: .trash, onPress: { print("Tapped") }, onDelete: { print("Deleted") })
        Tag("A very long tag name that might need truncation")
    }
    .padding()
    .preferredColorScheme(.dark)
}
