import SwiftUI

struct TextField: View {
    let placeholder: String
    let backgroundColor: Color
    let font: Font
    let axis: Axis
    let testIdentifier: String?
    @Binding var text: String

    init(
        _ placeholder: String,
        text: Binding<String>,
        backgroundColor: Color = .white10,
        font: Font = .custom(Fonts.semiBold, size: 15),
        axis: Axis = .horizontal,
        testIdentifier: String? = nil
    ) {
        self.placeholder = placeholder
        self.backgroundColor = backgroundColor
        self.font = font
        self.axis = axis
        self.testIdentifier = testIdentifier
        _text = text
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(.secondary)
                    .font(font)
            }

            SwiftUI.TextField("", text: $text, axis: axis)
                .accentColor(.brandAccent)
                .font(font)
                .accessibilityIdentifier(testIdentifier ?? "")
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(8)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var text1 = ""
        @State private var text2 = "Example text"

        var body: some View {
            VStack(spacing: 20) {
                TextField("Enter some text", text: $text1)
                TextField("Filled field", text: $text2)
            }
            .padding()
            .preferredColorScheme(.dark)
        }
    }

    return PreviewWrapper()
}
