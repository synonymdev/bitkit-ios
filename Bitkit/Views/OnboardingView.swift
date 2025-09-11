import SwiftUI

struct OnboardingView: View {
    // Required parameters
    let title: String
    let description: String
    let imageName: String
    let buttonText: String
    let onButtonPress: () -> Void

    // Optional parameters with defaults
    let navTitle: String
    let showBackButton: Bool
    let showMenuButton: Bool
    let titleColor: Color
    let accentColor: Color
    let imagePosition: ImagePosition
    let testID: String?

    enum ImagePosition {
        case center
        case bottom
    }

    init(
        navTitle: String? = nil,
        title: String,
        description: String,
        imageName: String,
        buttonText: String,
        showBackButton: Bool? = nil,
        showMenuButton: Bool? = nil,
        onButtonPress: @escaping () -> Void,
        titleColor: Color = .textPrimary,
        accentColor: Color = .brandAccent,
        imagePosition: ImagePosition = .bottom,
        testID: String? = nil
    ) {
        self.navTitle = navTitle ?? ""
        self.title = title
        self.description = description
        self.imageName = imageName
        self.buttonText = buttonText
        self.showBackButton = showBackButton ?? true
        self.showMenuButton = showMenuButton ?? true
        self.onButtonPress = onButtonPress
        self.titleColor = titleColor
        self.accentColor = accentColor
        self.imagePosition = imagePosition
        self.testID = testID
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: navTitle, showBackButton: showBackButton, showMenuButton: showMenuButton)

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

                VStack(alignment: .leading, spacing: 14) {
                    DisplayText(title, textColor: titleColor, accentColor: accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    BodyMText(description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CustomButton(title: buttonText) {
                    onButtonPress()
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .accessibilityIdentifier(testID ?? "")
    }
}

#Preview {
    NavigationStack {
        OnboardingView(
            navTitle: "Welcome",
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
