import SwiftUI

struct OnboardingView: View {
    // Required parameters
    let title: String
    let description: String
    let imageName: String
    let buttonText: String
    let onButtonPress: () -> Void

    // Optional parameters with defaults
    let titleColor: Color
    let accentColor: Color
    let imagePosition: ImagePosition
    let testID: String?

    enum ImagePosition {
        case center
        case bottom
    }

    init(
        title: String,
        description: String,
        imageName: String,
        buttonText: String,
        onButtonPress: @escaping () -> Void,
        titleColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        imagePosition: ImagePosition = .bottom,
        testID: String? = nil
    ) {
        self.title = title
        self.description = description
        self.imageName = imageName
        self.buttonText = buttonText
        self.onButtonPress = onButtonPress
        self.titleColor = titleColor
        self.accentColor = accentColor
        self.imagePosition = imagePosition
        self.testID = testID
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack {
                if imagePosition == .center {
                    Spacer()
                }

                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.bottom, imagePosition == .center ? 0 : 48)

                if imagePosition == .center {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 4) {
                DisplayText(title, textColor: titleColor, accentColor: accentColor)
                BodyMText(description)
            }

            CustomButton(title: buttonText) {
                onButtonPress()
            }
            .padding(.top, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
        .accessibilityIdentifier(testID ?? "")
    }
}

#Preview {
    NavigationStack {
        OnboardingView(
            title: "Welcome to Bitkit",
            description: "Your secure Bitcoin wallet",
            imageName: "bitcoin-emboss",
            buttonText: "Get Started",
            onButtonPress: {},
            imagePosition: .center
        )
        .preferredColorScheme(.dark)
    }
}
