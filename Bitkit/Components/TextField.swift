import SwiftUI

struct TextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(.secondary)
                    .font(.custom(Fonts.semiBold, size: 15))
            }

            SwiftUI.TextField("", text: $text)
                .submitLabel(.done)
                .accentColor(.brandAccent)
                .font(.custom(Fonts.semiBold, size: 15))
        }
        .padding()
        // NOTE: #1B1B1B is solid version of white10
        .background(Color(hex: 0x1B1B1B))
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
