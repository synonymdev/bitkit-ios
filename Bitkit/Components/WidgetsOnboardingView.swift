import SwiftUI

private struct WidgetsOnboardingText: View {
    let text: String
    private let fontSize: CGFloat = 24

    var body: some View {
        AccentedText(
            text,
            font: Fonts.black(size: fontSize),
            fontColor: .textPrimary,
            accentColor: .brandAccent,
            accentFont: Fonts.black(size: fontSize)
        )
        .kerning(-1)
        .environment(\._lineHeightMultiple, 0.83)
        .textCase(.uppercase)
        .padding(.bottom, -9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

struct WidgetsOnboardingView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            WidgetsOnboardingText(text: t("widgets__onboarding__swipe"))

            Image("swipe-hint")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 100)
        }
        .frame(height: 72)
        .frame(maxWidth: .infinity)
    }
}
