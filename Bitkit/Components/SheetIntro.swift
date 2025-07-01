import SwiftUI

struct SheetIntro: View {
    let navTitle: String
    let title: String
    let description: String
    let image: String
    let continueText: String
    let cancelText: String?
    let accentColor: Color
    let testID: String?
    let onCancel: (() -> Void)?
    let onContinue: () -> Void

    init(
        navTitle: String,
        title: String,
        description: String,
        image: String,
        continueText: String,
        cancelText: String? = nil,
        accentColor: Color = .brandAccent,
        testID: String? = nil,
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
        self.testID = testID
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

                DisplayText(title, accentColor: accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                BodyMText(description)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            buttonStack
                .padding(.top, 32)
        }
        .padding(.horizontal, 32)
        .accessibilityIdentifier(testID ?? "SheetIntro")
    }

    @ViewBuilder
    private var buttonStack: some View {
        if let cancelText = cancelText, let onCancel = onCancel {
            HStack(alignment: .center, spacing: 16) {
                CustomButton(
                    title: cancelText,
                    variant: .secondary
                ) {
                    onCancel()
                }

                CustomButton(
                    title: continueText
                ) {
                    onContinue()
                }
            }
        } else {
            CustomButton(
                title: continueText
            ) {
                onContinue()
            }
        }
    }
}
