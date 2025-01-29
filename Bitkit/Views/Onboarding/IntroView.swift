import SwiftUI

struct IntroView: View {
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
                
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 279, alignment: .center)
                
            Spacer()
                
            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("welcome_title"))
                    
                BodyMText(t("welcome_text"))
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
                
            HStack(spacing: 16) {
                NavigationLink(destination: OnboardingView()) {
                    CustomButton(title: t("get_started"))
                }
                    
                NavigationLink(destination: OnboardingView(currentTab: 4)) {
                    CustomButton(
                        title: t("skip_intro"),
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
