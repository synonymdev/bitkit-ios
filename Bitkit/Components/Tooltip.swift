import SwiftUI

struct Tooltip: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 8)

                Path { path in
                    path.move(to: CGPoint(x: 16, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: 16))
                    path.addLine(to: CGPoint(x: 32, y: 16))
                    path.closeSubpath()
                }
                .fill(Color.black92)
                .frame(width: 32, height: 16)
            }

            CaptionBText(text, textColor: .white)
                .padding(.vertical, 24)
                .padding(.horizontal, 32)
                .background(Color.black92)
                .cornerRadius(8)
        }
    }
}
