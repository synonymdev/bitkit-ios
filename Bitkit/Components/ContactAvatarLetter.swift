import SwiftUI

struct ContactAvatarLetter: View {
    let source: String
    let size: CGFloat
    var backgroundColor: Color = .white.opacity(0.1)
    var strokeColor: Color?
    var strokeWidth: CGFloat = 0
    var textFont: Font?
    /// Rounded square when set, circular otherwise.
    var cornerRadius: CGFloat?

    private var letter: String {
        String(source.prefix(1)).uppercased()
    }

    private var shape: AnyShape {
        cornerRadius.map { AnyShape(RoundedRectangle(cornerRadius: $0)) } ?? AnyShape(Circle())
    }

    var body: some View {
        shape
            .fill(backgroundColor)
            .frame(width: size, height: size)
            .overlay {
                avatarText
            }
            .overlay {
                if let strokeColor, strokeWidth > 0 {
                    shape.stroke(strokeColor, lineWidth: strokeWidth)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarText: some View {
        if let textFont {
            AccentedText(letter, font: textFont, fontColor: .textPrimary)
        } else if size >= 72 {
            HeadlineText(letter)
        } else if size >= 56 {
            TitleText(letter)
        } else if size >= 44 {
            BodyMSBText(letter)
        } else {
            CaptionBText(letter, textColor: .textPrimary)
        }
    }
}
