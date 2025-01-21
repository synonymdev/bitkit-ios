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
                    Text(t("get_started"))
                        .subtitleTextStyle()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray2)
                        .cornerRadius(30)
                }
                    
                NavigationLink(destination: OnboardingView(currentTab: 4)) {
                    Text(t("skip_intro"))
                        .subtitleTextStyle()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .overlay(
                            RoundedRectangle(cornerRadius: 30)
                                .stroke(Color.gray2, lineWidth: 1)
                        )
                        .cornerRadius(30)
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
