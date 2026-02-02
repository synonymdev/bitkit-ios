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
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            HStack(alignment: .bottom, spacing: 0) {
                WidgetsOnboardingText(text: t("widgets__onboarding__swipe"))

                Image("arrow-widgets")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 110)
                    .padding(.trailing, 32)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .overlay {
                VStack {
                    Button(action: {
                        Haptics.play(.buttonTap)
                        app.hasDismissedWidgetsOnboardingHint = true
                    }) {
                        Image("x-mark")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundColor(.textSecondary)
                            .frame(width: 16, height: 16)
                            .frame(width: 44, height: 44) // Increase hit area
                    }
                    .offset(x: 16, y: 0)

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
    }
}
