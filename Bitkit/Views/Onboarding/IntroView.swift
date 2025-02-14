import SwiftUI

struct IntroView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 279, alignment: .center)

            Spacer()

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(NSLocalizedString("onboarding__welcome_title", comment: ""))

                BodyMText(NSLocalizedString("onboarding__welcome_text", comment: ""), accentColor: .brandAccent)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                NavigationLink(destination: OnboardingView()) {
                    CustomButton(title: NSLocalizedString("onboarding__get_started", comment: ""))
                }

                NavigationLink(destination: OnboardingView(currentTab: 4)) {
                    CustomButton(
                        title: NSLocalizedString("onboarding__skip_intro", comment: ""),
                        variant: .secondary
                    )
                }
            }
        }
        .padding()
        .background(
            Image("figures")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        )
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
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
