import SwiftUI

struct CheckboxRow: View {
    let title: String
    let subtitle: String
    let subtitleUrl: URL?
    @Binding var isChecked: Bool
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading) {
                BodyMSBText(title)
                BodySSBText(
                    subtitle,
                    textColor: .textSecondary,
                    accentColor: .brandAccent,
                    url: subtitleUrl
                )
            }
            .padding(.vertical, 3)

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isChecked ? Color.brand32 : Color.white10)
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isChecked ? Color.brandAccent : Color.white32, lineWidth: 1)
                    )

                if isChecked {
                    Image("checkmark-orange")
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(isPressed ? 0.7 : 1.0)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    isPressed = true
                }
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isPressed = false
                    }
                    isChecked.toggle()
                }
        )
    }
}

#Preview {
    CheckboxRow(
        title: "Terms of Service",
        subtitle: "I accept the Terms of Service",
        subtitleUrl: URL(string: "https://example.com"),
        isChecked: .constant(false)
    )
    .padding()
    .preferredColorScheme(.dark)
}
