import SwiftUI

struct ClipboardCopyPopup: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 16) {
            BodyMSBText(title, textColor: .brandAccent)

            BodySText(value, textColor: .textPrimary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 247)
        .padding(32)
        .background(Color.gray6)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 25, x: 0, y: 25)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ClipboardCopyPopup(
        title: "pubky copied to clipboard",
        value: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.customBlack)
    .preferredColorScheme(.dark)
}
