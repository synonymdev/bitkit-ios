import SwiftUI
import UIKit

// Bugger headings need custom kerning and line spacing that isn't supported by SwiftUI perfectly so using a UIKit component for some text styles
struct DisplayText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var accentFont: String? = nil
    var textAlignment: NSTextAlignment = .left

    init(
        _ text: String, textColor: Color = .textPrimary, accentColor: Color = .brandAccent, accentFont: String? = nil,
        textAlignment: NSTextAlignment = .left
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.textAlignment = textAlignment
    }

    // TODO: lineHeight should be 44, but glyphs are cut off

    var body: some View {
        CustomTextWrapper(
            text: text, fontSize: 44, lineHeight: 47, shouldCapitalize: true, font: Fonts.black, textColor: textColor, accentColor: accentColor,
            accentFont: accentFont, kerning: -1, textAlignment: textAlignment)
    }
}

struct HeadlineText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var textAlignment: NSTextAlignment = .left

    init(_ text: String, textColor: Color = .textPrimary, accentColor: Color = .brandAccent, textAlignment: NSTextAlignment = .left) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.textAlignment = textAlignment
    }

    var body: some View {
        CustomTextWrapper(
            text: text, fontSize: 30, lineHeight: 30, shouldCapitalize: true, font: Fonts.black, textColor: textColor, accentColor: accentColor,
            kerning: -1, textAlignment: textAlignment)
    }
}

struct TitleText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var textAlignment: NSTextAlignment = .left

    init(_ text: String, textColor: Color = .textPrimary, accentColor: Color = .brandAccent, textAlignment: NSTextAlignment = .left) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.textAlignment = textAlignment
    }

    var body: some View {
        CustomTextWrapper(
            text: text, fontSize: 22, lineHeight: 26, shouldCapitalize: false, font: Fonts.bold, textColor: textColor, accentColor: accentColor,
            kerning: 0.4, textAlignment: textAlignment)
    }
}

struct SubtitleText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color = .brandAccent
    var textAlignment: NSTextAlignment = .left

    init(_ text: String, textColor: Color = .textPrimary, accentColor: Color = .brandAccent, textAlignment: NSTextAlignment = .left) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.textAlignment = textAlignment
    }

    var body: some View {
        CustomTextWrapper(
            text: text, fontSize: 17, lineHeight: 22, shouldCapitalize: false, font: Fonts.bold, textColor: textColor, accentColor: accentColor,
            kerning: 0.4, textAlignment: textAlignment)
    }
}

struct BodyMText: View {
    let text: String
    let font = Fonts.regular
    var textColor: Color = .textSecondary
    var accentColor: Color = .white
    var accentFont: String? = nil
    var textAlignment: NSTextAlignment = .left

    init(
        _ text: String, textColor: Color = .textSecondary, accentColor: Color = .white, accentFont: String? = nil,
        textAlignment: NSTextAlignment = .left
    ) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.textAlignment = textAlignment
    }

    var body: some View {
        CustomTextWrapper(
            text: text, fontSize: 17, lineHeight: 22, shouldCapitalize: false, font: font, textColor: textColor,
            accentColor: accentColor, accentFont: accentFont, kerning: 0.4, textAlignment: textAlignment)
    }
}

struct BodyMSBText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color? = nil
    private let fontSize: CGFloat = 17

    init(_ text: String, textColor: Color = .textPrimary, accentColor: Color? = nil) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
    }

    var body: some View {
        Text(
            AttributedString(parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, fontSize: fontSize, font: Fonts.semiBold))
        )
        .font(.custom(Fonts.semiBold, size: fontSize))
        .kerning(0.4)
    }
}

struct BodyMBoldText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color = .brandAccent
    private let fontSize: CGFloat = 17

    init(_ text: String, textColor: Color = .textSecondary, accentColor: Color = .brandAccent) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
    }

    var body: some View {
        Text(AttributedString(parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, fontSize: fontSize, font: Fonts.bold)))
            .font(.custom(Fonts.bold, size: fontSize))
            .kerning(0.4)
    }
}

struct BodySText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color? = nil
    var url: URL? = nil
    private let fontSize: CGFloat = 15

    init(_ text: String, textColor: Color = .textSecondary, accentColor: Color? = nil, url: URL? = nil) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.url = url
    }

    var body: some View {
        Text(
            AttributedString(
                parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, url: url, fontSize: fontSize, font: Fonts.regular))
        )
        .font(.custom(Fonts.regular, size: fontSize))
        .kerning(0.4)
        .tint(accentColor ?? .brandAccent)
    }
}

struct BodySSBText: View {
    let text: String
    var textColor: Color = .textPrimary
    var accentColor: Color? = nil
    var url: URL? = nil
    private let fontSize: CGFloat = 15

    init(_ text: String, textColor: Color = .textPrimary, accentColor: Color? = nil, url: URL? = nil) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
        self.url = url
    }

    var body: some View {
        Text(
            AttributedString(
                parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, url: url, fontSize: fontSize, font: Fonts.semiBold))
        )
        .font(.custom(Fonts.semiBold, size: fontSize))
        .kerning(0.4)
        .lineSpacing(1)
        .tint(accentColor ?? .brandAccent)
    }
}

struct CaptionText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color? = nil
    private let fontSize: CGFloat = 13

    init(_ text: String, textColor: Color = .textSecondary, accentColor: Color? = nil) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
    }

    var body: some View {
        Text(
            AttributedString(parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, fontSize: fontSize, font: Fonts.regular))
        )
        .font(.custom(Fonts.regular, size: fontSize))
        .kerning(0.4)
    }
}

struct CaptionBText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color? = nil
    private let fontSize: CGFloat = 13

    init(_ text: String, textColor: Color = .textSecondary, accentColor: Color? = nil) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
    }

    var body: some View {
        Text(
            AttributedString(parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, fontSize: fontSize, font: Fonts.semiBold))
        )
        .font(.custom(Fonts.regular, size: fontSize))
        .kerning(0.4)
    }
}

struct FootnoteText: View {
    let text: String
    var textColor: Color = .textSecondary
    var accentColor: Color? = nil
    private let fontSize: CGFloat = 12

    init(_ text: String, textColor: Color = .textSecondary, accentColor: Color? = nil) {
        self.text = text
        self.textColor = textColor
        self.accentColor = accentColor
    }

    var body: some View {
        Text(AttributedString(parseAccentTags(text: text, defaultColor: textColor, accentColor: accentColor, fontSize: fontSize, font: Fonts.medium)))
            .font(.custom(Fonts.medium, size: fontSize))
            .kerning(0.4)
    }
}

// Helper function to parse accent tags
private func parseAccentTags(
    text: String, defaultColor: Color, accentColor: Color?, url: URL? = nil, fontSize: CGFloat = 15, font: String = Fonts.regular,
    accentFont: String? = nil
) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(string: "")
    var currentIndex = text.startIndex

    while currentIndex < text.endIndex {
        if let accentStartRange = text[currentIndex...].range(of: "<accent>") {
            // Add text before the accent tag
            let beforeAccent = String(text[currentIndex ..< accentStartRange.lowerBound])
            if !beforeAccent.isEmpty {
                let normalString = NSAttributedString(
                    string: beforeAccent,
                    attributes: [
                        .foregroundColor: UIColor(defaultColor),
                        .font: UIFont(name: font, size: fontSize) ?? .systemFont(ofSize: fontSize),
                    ])
                attributedString.append(normalString)
            }

            // Find the end of accent tag
            if let accentEndRange = text[accentStartRange.upperBound...].range(of: "</accent>") {
                // Get the accented text
                let accentedText = String(text[accentStartRange.upperBound ..< accentEndRange.lowerBound])
                var attributes: [NSAttributedString.Key: Any] = [:]

                if let accentColor = accentColor {
                    attributes[.foregroundColor] = UIColor(accentColor)
                    attributes[.font] = UIFont(name: accentFont ?? font, size: fontSize) ?? .systemFont(ofSize: fontSize)
                } else {
                    attributes[.foregroundColor] = UIColor(defaultColor)
                    attributes[.font] = UIFont(name: Fonts.bold, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .bold)
                }

                if let url = url {
                    attributes[.link] = url
                }

                let accentString = NSAttributedString(string: accentedText, attributes: attributes)
                attributedString.append(accentString)

                currentIndex = accentEndRange.upperBound
            } else {
                // No closing tag found, treat rest as normal text
                let remainingText = String(text[accentStartRange.lowerBound...])
                let normalString = NSAttributedString(
                    string: remainingText,
                    attributes: [
                        .foregroundColor: UIColor(defaultColor),
                        .font: UIFont(name: font, size: fontSize) ?? .systemFont(ofSize: fontSize),
                    ])
                attributedString.append(normalString)
                break
            }
        } else {
            // No more accent tags, add remaining text
            let remainingText = String(text[currentIndex...])
            let normalString = NSAttributedString(
                string: remainingText,
                attributes: [
                    .foregroundColor: UIColor(defaultColor),
                    .font: UIFont(name: font, size: fontSize) ?? .systemFont(ofSize: fontSize),
                ])
            attributedString.append(normalString)
            break
        }
    }

    return attributedString
}

private struct ViewWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CustomTextWrapper: View {
    let text: String
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let shouldCapitalize: Bool
    let font: String
    let textColor: Color
    let accentColor: Color
    let accentFont: String?
    let kerning: CGFloat
    let textAlignment: NSTextAlignment
    @State private var viewWidth: CGFloat = 0

    init(
        text: String, fontSize: CGFloat, lineHeight: CGFloat, shouldCapitalize: Bool, font: String, textColor: Color, accentColor: Color,
        accentFont: String? = nil, kerning: CGFloat, textAlignment: NSTextAlignment = .left
    ) {
        self.text = text
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.shouldCapitalize = shouldCapitalize
        self.font = font
        self.textColor = textColor
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.kerning = kerning
        self.textAlignment = textAlignment
    }

    var body: some View {
        GeometryReader { geometry in
            DisplayTextUIView(
                text: text, fontSize: fontSize, lineHeight: lineHeight, width: geometry.size.width, shouldCapitalize: shouldCapitalize, font: font,
                textColor: textColor, accentColor: accentColor, accentFont: accentFont ?? font, kerning: kerning, textAlignment: textAlignment
            )
            .preference(key: ViewWidthKey.self, value: geometry.size.width)
        }
        // .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: calculateHeight())
        .onPreferenceChange(ViewWidthKey.self) { width in
            viewWidth = width
        }
    }

    private func calculateHeight() -> CGFloat {
        let label = UILabel()
        label.font = UIFont(name: font, size: fontSize)
        label.numberOfLines = 0

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.alignment = textAlignment

        // Parse text for accent tags and create attributed string
        let attributedString = NSMutableAttributedString(string: "")

        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            if let accentStartRange = text[currentIndex...].range(of: "<accent>") {
                // Add text before the accent tag
                let beforeAccent = String(text[currentIndex ..< accentStartRange.lowerBound])
                let processedText = shouldCapitalize ? beforeAccent.uppercased() : beforeAccent
                if !beforeAccent.isEmpty {
                    let normalString = NSMutableAttributedString(string: processedText)
                    normalString.addAttribute(.foregroundColor, value: UIColor(textColor), range: NSRange(location: 0, length: processedText.count))
                    attributedString.append(normalString)
                }

                // Find the end of accent tag
                if let accentEndRange = text[accentStartRange.upperBound...].range(of: "</accent>") {
                    // Get the accented text
                    let accentedText = String(text[accentStartRange.upperBound ..< accentEndRange.lowerBound])
                    let processedAccentText = shouldCapitalize ? accentedText.uppercased() : accentedText
                    let accentString = NSMutableAttributedString(string: processedAccentText)
                    if let font = UIFont(name: accentFont ?? font, size: fontSize) {
                        accentString.addAttributes(
                            [
                                .foregroundColor: UIColor(accentColor),
                                .font: font,
                            ], range: NSRange(location: 0, length: processedAccentText.count))
                    }
                    attributedString.append(accentString)

                    currentIndex = accentEndRange.upperBound
                } else {
                    // No closing tag found, treat rest as normal text
                    let remainingText = String(text[accentStartRange.lowerBound...])
                    let processedText = shouldCapitalize ? remainingText.uppercased() : remainingText
                    let normalString = NSMutableAttributedString(string: processedText)
                    normalString.addAttribute(.foregroundColor, value: UIColor(textColor), range: NSRange(location: 0, length: processedText.count))
                    attributedString.append(normalString)
                    break
                }
            } else {
                // No more accent tags, add remaining text
                let remainingText = String(text[currentIndex...])
                let processedText = shouldCapitalize ? remainingText.uppercased() : remainingText
                let normalString = NSMutableAttributedString(string: processedText)
                normalString.addAttribute(.foregroundColor, value: UIColor(textColor), range: NSRange(location: 0, length: processedText.count))
                attributedString.append(normalString)
                break
            }
        }

        // Apply common attributes
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.baselineOffset, value: 0, range: NSRange(location: 0, length: attributedString.length))

        label.attributedText = attributedString

        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        let size = label.sizeThatFits(CGSize(width: viewWidth, height: .infinity))
        return size.height
    }
}

struct DisplayTextUIView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let width: CGFloat
    let shouldCapitalize: Bool
    let font: String
    let textColor: Color
    let accentColor: Color
    let accentFont: String
    let kerning: CGFloat
    let textAlignment: NSTextAlignment

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: DisplayTextUIView

        init(_ parent: DisplayTextUIView) {
            self.parent = parent
        }
    }

    private func updateLabel(_ label: UILabel) {
        label.font = UIFont(name: font, size: fontSize)
        label.textColor = UIColor(textColor)
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.textAlignment = textAlignment

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.alignment = textAlignment

        // Parse text for accent tags and create attributed string
        let attributedString = NSMutableAttributedString(string: "")

        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            if let accentStartRange = text[currentIndex...].range(of: "<accent>") {
                // Add text before the accent tag
                let beforeAccent = String(text[currentIndex ..< accentStartRange.lowerBound])
                let processedText = shouldCapitalize ? beforeAccent.uppercased() : beforeAccent
                if !beforeAccent.isEmpty {
                    let normalString = NSMutableAttributedString(string: processedText)
                    normalString.addAttribute(.foregroundColor, value: UIColor(textColor), range: NSRange(location: 0, length: processedText.count))
                    attributedString.append(normalString)
                }

                // Find the end of accent tag
                if let accentEndRange = text[accentStartRange.upperBound...].range(of: "</accent>") {
                    // Get the accented text
                    let accentedText = String(text[accentStartRange.upperBound ..< accentEndRange.lowerBound])
                    let processedAccentText = shouldCapitalize ? accentedText.uppercased() : accentedText
                    let accentString = NSMutableAttributedString(string: processedAccentText)
                    if let font = UIFont(name: accentFont, size: fontSize) {
                        accentString.addAttributes(
                            [
                                .foregroundColor: UIColor(accentColor),
                                .font: font,
                            ], range: NSRange(location: 0, length: processedAccentText.count))
                    }
                    attributedString.append(accentString)

                    currentIndex = accentEndRange.upperBound
                } else {
                    // No closing tag found, treat rest as normal text
                    let remainingText = String(text[accentStartRange.lowerBound...])
                    let processedText = shouldCapitalize ? remainingText.uppercased() : remainingText
                    let normalString = NSMutableAttributedString(string: processedText)
                    normalString.addAttribute(.foregroundColor, value: UIColor(textColor), range: NSRange(location: 0, length: processedText.count))
                    attributedString.append(normalString)
                    break
                }
            } else {
                // No more accent tags, add remaining text
                let remainingText = String(text[currentIndex...])
                let processedText = shouldCapitalize ? remainingText.uppercased() : remainingText
                let normalString = NSMutableAttributedString(string: processedText)
                normalString.addAttribute(.foregroundColor, value: UIColor(textColor), range: NSRange(location: 0, length: processedText.count))
                attributedString.append(normalString)
                break
            }
        }

        // Apply common attributes
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.baselineOffset, value: 0, range: NSRange(location: 0, length: attributedString.length))

        label.attributedText = attributedString

        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    func makeUIView(context _: Context) -> UILabel {
        let label = UILabel()
        updateLabel(label)
        return label
    }

    func updateUIView(_ uiView: UILabel, context _: Context) {
        updateLabel(uiView)
    }

    static func dismantleUIView(_: UILabel, coordinator _: Coordinator) {}
}

#Preview {
    ScrollView {
        HStack {
            DisplayText(NSLocalizedString("onboarding__empty_wallet", comment: ""))
                .background(Color.red.opacity(0.1))

            DisplayText(NSLocalizedString("onboarding__welcome_title", comment: ""))
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

        DisplayText(NSLocalizedString("onboarding__slide0_header", comment: ""))
            .background(Color.orange.opacity(0.1))
            .padding(.bottom, 20)

        DisplayText("Display Style With An\n<accent>Accent</accent> Over Here")
            .background(Color.green.opacity(0.1))
            .padding(.bottom, 20)
    }
    .padding()
}
