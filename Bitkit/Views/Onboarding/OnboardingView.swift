import SwiftUI

struct OnboardingView: View {
    @State var currentTab = 0
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        VStack {
            TabView(selection: $currentTab) {
                // Slide 0
                OnboardingTab(
                    imageName: "keyring",
                    title: t.parts("slide0_header"),
                    text: t.parts("slide0_text"),
                    secondLineColor: .blue
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(0)
                
                // Slide 1
                OnboardingTab(
                    imageName: "lightning",
                    title: t.parts("slide1_header"),
                    text: t.parts("slide1_text"),
                    disclaimerText: t("slide1_note"),
                    secondLineColor: .purple
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(1)
                
                // Slide 2
                OnboardingTab(
                    imageName: "spark",
                    title: t.parts("slide2_header"),
                    text: t.parts("slide2_text"),
                    secondLineColor: .yellow
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(2)
                
                // Slide 3
                OnboardingTab(
                    imageName: "shield",
                    title: t.parts("slide3_header"),
                    text: t.parts("slide3_text"),
                    secondLineColor: .green
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(3)
                
                CreateWalletView()
                    .padding(.horizontal, 32)
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            // Page indicator dots
            HStack(spacing: 8) {
                ForEach(0 ..< 5) { index in
                    Circle()
                        .fill(currentTab == index ? Color.primary : Color.secondary)
                        .frame(width: 7, height: 7)
                }
            }
            .opacity(currentTab == 4 ? 0 : 1)
            .offset(y: currentTab == 4 ? 20 : 0)
            .animation(.easeInOut(duration: 0.3), value: currentTab)
            .padding(.bottom)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if currentTab == 4 {
                    NavigationLink(t("advanced_setup")) {
                        CreateWalletWithPassphraseView()
                    }
                } else {
                    Button(t("skip")) {
                        withAnimation {
                            currentTab = 4
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    OnboardingView()
}
