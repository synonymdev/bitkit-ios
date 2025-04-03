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
                DisplayText(NSLocalizedString("onboarding__welcome_title", comment: ""))

                BodyMText(NSLocalizedString("onboarding__welcome_text", comment: ""), textColor: .textSecondary, accentColor: .brandAccent)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                CustomButton(title: NSLocalizedString("onboarding__get_started", comment: ""), destination: OnboardingView())
                CustomButton(
                    title: NSLocalizedString("onboarding__skip_intro", comment: ""),
                    variant: .secondary,
                    destination: OnboardingView(currentTab: 4)
                )
            }
        }
        .padding(.horizontal, 32)
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
    NavigationView {
        IntroView()
    }
    .preferredColorScheme(.dark)
}

#Preview {
    NavigationView {
        IntroView()
    }
    .preferredColorScheme(.light)
}
