import SwiftUI

struct LabeledDetailCell: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(title.localizedUppercase, textColor: .white64)
            HStack(spacing: 4) {
                Image(icon)
                    .resizable()
                    .foregroundColor(.purpleAccent)
                    .frame(width: 16, height: 16)
                BodySSBText(value)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white16).frame(height: 1)
        }
    }
}
