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
                parts.reduce(Text("")) { current, part in
                    current + Text(part.text.uppercased())
                        .font(.system(size: 44, weight: .black))
                        .foregroundColor(part.isAccent ? Color.brandAccent : .primary)
                }
                    
                Text(t("welcome_text"))
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
                
            HStack(spacing: 16) {
                NavigationLink(destination: OnboardingView()) {
                    Text(t("get_started"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .background(Color.gray)
                        .cornerRadius(30)
                }
                    
                NavigationLink(destination: OnboardingView(currentTab: 4)) {
                    Text(t("skip_intro"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 30)
                                .stroke(Color.gray, lineWidth: 1)
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
