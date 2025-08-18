import SwiftUI

struct IntroView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 279, alignment: .center)
                .padding(.bottom, 90)

            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("onboarding__welcome_title"))

                BodyMText(t("onboarding__welcome_text"), textColor: .textSecondary, accentColor: .brandAccent)
                    .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                CustomButton(title: t("onboarding__get_started"), destination: OnboardingSlider())
                CustomButton(
                    title: t("onboarding__skip_intro"),
                    variant: .secondary,
                    destination: OnboardingSlider(currentTab: 4)
                )
            }
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
        .background(
            Image("figures")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        )
        .navigationBarBackButtonHidden(true)
    }
}

#Preview {
    NavigationStack {
        IntroView()
    }
    .preferredColorScheme(.dark)
}
