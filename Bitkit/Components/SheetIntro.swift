import SwiftUI

struct SheetIntro: View {
    let navTitle: String
    let title: String
    let description: String
    let image: String
    let continueText: String
    let cancelText: String?
    let accentColor: Color
    let accentFont: ((CGFloat) -> Font)?
    let testID: String?
    let continueTestID: String?
    let onCancel: (() -> Void)?
    let onContinue: () -> Void
    private var baseTestID: String {
        testID ?? "SheetIntro"
    }

    init(
        navTitle: String,
        title: String,
        description: String,
        image: String,
        continueText: String,
        cancelText: String? = nil,
        accentColor: Color = .brandAccent,
        accentFont: ((CGFloat) -> Font)? = nil,
        testID: String? = nil,
        continueTestID: String? = nil,
        onCancel: (() -> Void)? = nil,
        onContinue: @escaping () -> Void
    ) {
        self.navTitle = navTitle
        self.title = title
        self.description = description
        self.image = image
        self.continueText = continueText
        self.cancelText = cancelText
        self.accentColor = accentColor
        self.accentFont = accentFont
        self.testID = testID
        self.continueTestID = continueTestID
        self.onCancel = onCancel
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: navTitle)

            VStack(spacing: 0) {
                Spacer()

                Image(image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)
                    .padding(.bottom, 32)
                    .accessibilityIdentifier("\(baseTestID)Image")

                DisplayText(title, accentColor: accentColor)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)

                BodyMText(description, accentFont: accentFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("\(baseTestID)Description")
            }

            buttonStack
                .padding(.top, 32)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(baseTestID)
    }

    private var continueButtonTestID: String {
        continueTestID ?? "\(baseTestID)Continue"
    }

    @ViewBuilder
    private var buttonStack: some View {
        if let cancelText, let onCancel {
            HStack(alignment: .center, spacing: 16) {
                CustomButton(
                    title: cancelText,
                    variant: .secondary
                ) {
                    onCancel()
                }
                .accessibilityIdentifier("\(baseTestID)Cancel")

                CustomButton(
                    title: continueText
                ) {
                    onContinue()
                }
                .accessibilityIdentifier(continueButtonTestID)
            }
        } else {
            CustomButton(
                title: continueText
            ) {
                onContinue()
            }
            .accessibilityIdentifier(continueButtonTestID)
        }
    }
}
