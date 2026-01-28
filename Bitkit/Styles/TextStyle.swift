import SwiftUI

// We have some requirements for text styles:
// - The custom font (InterTight) has extra bottom space -> negative padding
// - We need to set a smaller than supported line height (without cutting off glyphs) -> (deprecated) lineHeightMultiple
// - Customize <accent> text (color, weight, action) -> helper functions
// - kerning & .lineLimit() -> supported by SwiftUI

struct DisplayText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 44

    init(
        _ text: String,
        textColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.black(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(-1)
        .environment(\._lineHeightMultiple, 0.83)
        .textCase(.uppercase)
        .padding(.bottom, -9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

struct HeadlineText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 30

    init(
        _ text: String,
        textColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.black(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(-1)
        .environment(\._lineHeightMultiple, 0.83)
        .textCase(.uppercase)
        .padding(.bottom, -6)
    }
}

struct TitleText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 22

    init(
        _ text: String,
        textColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.bold(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct SubtitleText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 17

    init(
        _ text: String,
        textColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.bold(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct BodyMText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .white
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 17

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .white,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.regular(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct BodyMSBText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 17

    init(
        _ text: String,
        textColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.semiBold(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct BodyMBoldText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 17

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.bold(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct BodySText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 15

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.regular(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct BodySSBText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 15

    init(
        _ text: String,
        textColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.semiBold(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
        // .lineSpacing(0)
    }
}

struct CaptionText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 13

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.regular(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct CaptionBText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 13

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.semiBold(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct CaptionMText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 13

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.medium(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.8)
        .textCase(.uppercase)
    }
}

struct FootnoteText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    var accentFont: ((CGFloat) -> Font)?
    var accentAction: (() -> Void)?

    private let fontSize: CGFloat = 12

    init(
        _ text: String,
        textColor: Color = .textSecondary,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        AccentedText(
            text,
            font: Fonts.medium(size: fontSize),
            fontColor: textColor,
            accentColor: accentColor,
            accentFont: accentFont?(fontSize),
            accentAction: accentAction
        )
        .kerning(0.4)
    }
}

struct AccentedText: View {
    let text: String
    let font: Font
    let fontColor: Color
    let accentColor: Color
    let accentFont: Font?
    let accentAction: (() -> Void)?

    init(
        _ text: String,
        font: Font = .system(size: 17),
        fontColor: Color = .primary,
        accentColor: Color = .accentColor,
        accentFont: Font? = nil,
        accentAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.font = font
        self.fontColor = fontColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.accentAction = accentAction
    }

    var body: some View {
        let parts = parseAccentTags(from: text)

        // If there's no accent action, use the simple concatenated text approach
        if accentAction == nil {
            let combinedText = parts.reduce(Text("")) { result, part in
                let selectedFont = part.isAccented ? (accentFont ?? font) : font
                let baseText = Text(part.text)
                    .font(selectedFont)
                    .foregroundColor(part.isAccented ? accentColor : fontColor)

                return result + baseText
            }
            combinedText
            // .background(Color.gray3)
        } else {
            // Use a flexible layout that allows tap gestures
            FlexibleTextView(
                parts: parts, font: font, fontColor: fontColor, accentColor: accentColor, accentFont: accentFont, accentAction: accentAction
            )
        }
    }

    private func parseAccentTags(from text: String) -> [TextPart] {
        var parts: [TextPart] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if let accentStartRange = text[currentIndex...].range(of: "<accent>") {
                // Add text before the accent tag
                let beforeAccent = String(text[currentIndex ..< accentStartRange.lowerBound])
                if !beforeAccent.isEmpty {
                    parts.append(TextPart(text: beforeAccent, isAccented: false))
                }

                // Find the end of accent tag
                if let accentEndRange = text[accentStartRange.upperBound...].range(of: "</accent>") {
                    // Get the accented text
                    let accentedText = String(text[accentStartRange.upperBound ..< accentEndRange.lowerBound])
                    parts.append(TextPart(text: accentedText, isAccented: true))
                    currentIndex = accentEndRange.upperBound
                } else {
                    // No closing tag found, treat rest as normal text
                    let remainingText = String(text[accentStartRange.lowerBound...])
                    parts.append(TextPart(text: remainingText, isAccented: false))
                    break
                }
            } else {
                // No more accent tags, add remaining text
                let remainingText = String(text[currentIndex...])
                parts.append(TextPart(text: remainingText, isAccented: false))
                break
            }
        }

        return parts
    }
}

private struct TextPart {
    let text: String
    let isAccented: Bool
}

private struct FlexibleTextView: View {
    let parts: [TextPart]
    let font: Font
    let fontColor: Color
    let accentColor: Color
    let accentFont: Font?
    let accentAction: (() -> Void)?

    var body: some View {
        Text(createAttributedString())
            .environment(
                \.openURL,
                OpenURLAction { url in
                    if url.absoluteString == "bitkit://accent-tap" {
                        accentAction?()
                        return .handled
                    }
                    return .systemAction
                }
            )
    }

    private func createAttributedString() -> AttributedString {
        var result = AttributedString()

        for part in parts {
            var attributedPart = AttributedString(part.text)

            if part.isAccented {
                attributedPart.font = accentFont ?? font
                attributedPart.foregroundColor = accentColor
                if accentAction != nil {
                    attributedPart.link = URL(string: "bitkit://accent-tap")
                }
            } else {
                attributedPart.font = font
                attributedPart.foregroundColor = fontColor
            }

            result.append(attributedPart)
        }

        return result
    }
}

#Preview {
    ScrollView {
        HStack {
            DisplayText(t("onboarding__empty_wallet"))
                .background(Color.red.opacity(0.1))

            DisplayText(t("onboarding__welcome_title"))
                .background(Color.blue.opacity(0.1))
        }
        .padding(.bottom, 20)

        HStack {
            DisplayText("One")
                .background(Color.red.opacity(0.1))

            DisplayText("Two")
                .background(Color.blue.opacity(0.1))
        }
        .padding(.bottom, 20)

        DisplayText(t("onboarding__slide0_header"))
            .background(Color.orange.opacity(0.1))
            .padding(.bottom, 20)

        DisplayText("Display Style With An\n<accent>Accent</accent> Over Here")
            .background(Color.green.opacity(0.1))
            .padding(.bottom, 20)

        BodyMText(
            "This is body text with a\n<accent>tappable link</accent> inside",
            accentAction: {
                print("Accent text was tapped!")
            }
        )
        .background(Color.purple.opacity(0.1))
        .padding(.bottom, 20)
    }
    .padding()
}
