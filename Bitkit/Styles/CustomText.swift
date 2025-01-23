import SwiftUI
import UIKit

struct DisplayText: View {
    let text: String

    var body: some View {
        CustomTextWrapper(text: text, fontSize: 44, lineHeight: 44)
    }
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
    @State private var viewWidth: CGFloat = 0

    init(text: String, fontSize: CGFloat, lineHeight: CGFloat) {
        self.text = text
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    var body: some View {
        GeometryReader { geometry in
            DisplayTextUIView(text: text, fontSize: fontSize, lineHeight: lineHeight, width: geometry.size.width)
                .preference(key: ViewWidthKey.self, value: geometry.size.width)
        }
        .frame(height: calculateHeight())
        .onPreferenceChange(ViewWidthKey.self) { width in
            viewWidth = width
        }
    }

    private func calculateHeight() -> CGFloat {
        let label = UILabel()
        label.font = UIFont(name: Fonts.black, size: fontSize)
        label.numberOfLines = 0

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.alignment = .left

        // Parse text for accent tags and create attributed string
        let attributedString = NSMutableAttributedString(string: "")

        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            if let accentStartRange = text[currentIndex...].range(of: "<accent>") {
                // Add text before the accent tag
                let beforeAccent = String(text[currentIndex..<accentStartRange.lowerBound]).uppercased()
                if !beforeAccent.isEmpty {
                    let normalString = NSMutableAttributedString(string: beforeAccent)
                    normalString.addAttribute(.foregroundColor, value: UIColor(Color.textPrimary), range: NSRange(location: 0, length: beforeAccent.count))
                    attributedString.append(normalString)
                }

                // Find the end of accent tag
                if let accentEndRange = text[accentStartRange.upperBound...].range(of: "</accent>") {
                    // Get the accented text
                    let accentedText = String(text[accentStartRange.upperBound..<accentEndRange.lowerBound]).uppercased()
                    let accentString = NSMutableAttributedString(string: accentedText)
                    accentString.addAttribute(.foregroundColor, value: UIColor(Color.brandAccent), range: NSRange(location: 0, length: accentedText.count))
                    attributedString.append(accentString)

                    currentIndex = accentEndRange.upperBound
                } else {
                    // No closing tag found, treat rest as normal text
                    let remainingText = String(text[accentStartRange.lowerBound...]).uppercased()
                    let normalString = NSMutableAttributedString(string: remainingText)
                    normalString.addAttribute(.foregroundColor, value: UIColor(Color.textPrimary), range: NSRange(location: 0, length: remainingText.count))
                    attributedString.append(normalString)
                    break
                }
            } else {
                // No more accent tags, add remaining text
                let remainingText = String(text[currentIndex...]).uppercased()
                let normalString = NSMutableAttributedString(string: remainingText)
                normalString.addAttribute(.foregroundColor, value: UIColor(Color.textPrimary), range: NSRange(location: 0, length: remainingText.count))
                attributedString.append(normalString)
                break
            }
        }

        // Apply common attributes
        attributedString.addAttribute(.kern, value: -1.0, range: NSRange(location: 0, length: attributedString.length))
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
        label.font = UIFont(name: Fonts.black, size: fontSize)
        label.textColor = UIColor(Color.textPrimary)
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = width

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.alignment = .left

        // Parse text for accent tags and create attributed string
        let attributedString = NSMutableAttributedString(string: "")

        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            if let accentStartRange = text[currentIndex...].range(of: "<accent>") {
                // Add text before the accent tag
                let beforeAccent = String(text[currentIndex..<accentStartRange.lowerBound]).uppercased()
                if !beforeAccent.isEmpty {
                    let normalString = NSMutableAttributedString(string: beforeAccent)
                    normalString.addAttribute(.foregroundColor, value: UIColor(Color.textPrimary), range: NSRange(location: 0, length: beforeAccent.count))
                    attributedString.append(normalString)
                }

                // Find the end of accent tag
                if let accentEndRange = text[accentStartRange.upperBound...].range(of: "</accent>") {
                    // Get the accented text
                    let accentedText = String(text[accentStartRange.upperBound..<accentEndRange.lowerBound]).uppercased()
                    let accentString = NSMutableAttributedString(string: accentedText)
                    accentString.addAttribute(.foregroundColor, value: UIColor(Color.brandAccent), range: NSRange(location: 0, length: accentedText.count))
                    attributedString.append(accentString)

                    currentIndex = accentEndRange.upperBound
                } else {
                    // No closing tag found, treat rest as normal text
                    let remainingText = String(text[accentStartRange.lowerBound...]).uppercased()
                    let normalString = NSMutableAttributedString(string: remainingText)
                    normalString.addAttribute(.foregroundColor, value: UIColor(Color.textPrimary), range: NSRange(location: 0, length: remainingText.count))
                    attributedString.append(normalString)
                    break
                }
            } else {
                // No more accent tags, add remaining text
                let remainingText = String(text[currentIndex...]).uppercased()
                let normalString = NSMutableAttributedString(string: remainingText)
                normalString.addAttribute(.foregroundColor, value: UIColor(Color.textPrimary), range: NSRange(location: 0, length: remainingText.count))
                attributedString.append(normalString)
                break
            }
        }

        // Apply common attributes
        attributedString.addAttribute(.kern, value: -1.0, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.baselineOffset, value: 0, range: NSRange(location: 0, length: attributedString.length))

        label.attributedText = attributedString

        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        updateLabel(label)
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        updateLabel(uiView)
    }

    static func dismantleUIView(_ uiView: UILabel, coordinator: Coordinator) {}
}

#Preview {
    ScrollView {
        let t = useTranslation(.onboarding)

        HStack {
            DisplayText(text: t("empty_wallet"))
                .background(Color.red.opacity(0.1))

            DisplayText(text: t("welcome_title"))
                .background(Color.blue.opacity(0.1))
        }
        .padding(.bottom, 20)

        DisplayText(text: t("slide0_header"))
            .background(Color.orange.opacity(0.1))
            .padding(.bottom, 20)

        DisplayText(text: "Display Style With An\n<accent>Accent</accent> Over Here")
            .background(Color.green.opacity(0.1))
            .padding(.bottom, 20)
    }
    .padding()
}
