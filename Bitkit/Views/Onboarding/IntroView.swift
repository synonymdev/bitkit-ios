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
                let parts = t.parts("welcome_title")
                (parts.reduce(Text("")) { current, part in
                    current + Text(part.text.uppercased()).foregroundColor(part.isAccent ? .brandAccent : .textPrimary)
                })
                .displayTextStyle()
                    
                Text(t("welcome_text"))
                    .bodyMTextStyle(color: .textSecondary)
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
