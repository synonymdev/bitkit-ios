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
    let titleDescriptionSpacing: CGFloat
    let buttonHorizontalPadding: CGFloat
    let maxImageSize: CGFloat?
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
        titleDescriptionSpacing: CGFloat = 14,
        buttonHorizontalPadding: CGFloat = 16,
        maxImageSize: CGFloat? = nil,
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
        self.titleDescriptionSpacing = titleDescriptionSpacing
        self.buttonHorizontalPadding = buttonHorizontalPadding
        self.maxImageSize = maxImageSize
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
                        .frame(maxWidth: maxImageSize ?? .infinity, maxHeight: maxImageSize)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.bottom, imagePosition == .center ? 0 : 48)

                    if imagePosition == .center {
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: titleDescriptionSpacing) {
                    DisplayText(title, textColor: titleColor, accentColor: accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    BodyMText(description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)

                CustomButton(title: buttonText) {
                    onButtonPress()
                }
                .padding(.top, 32)
                .padding(.horizontal, buttonHorizontalPadding)
                .accessibilityIdentifierIfPresent(testID.map { "\($0)-button" })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifierIfPresent(testID)
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
