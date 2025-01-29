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
                    title: t("slide0_header"),
                    text: t("slide0_text"),
                    accentColor: .blueAccent
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(0)
                
                // Slide 1
                OnboardingTab(
                    imageName: "lightning",
                    title: t("slide1_header"),
                    text: t("slide1_text"),
                    disclaimerText: t("slide1_note"),
                    accentColor: .purpleAccent
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(1)
                
                // Slide 2
                OnboardingTab(
                    imageName: "spark",
                    title: t("slide2_header"),
                    text: t("slide2_text"),
                    accentColor: .yellowAccent
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(2)
                
                // Slide 3
                OnboardingTab(
                    imageName: "shield",
                    title: t("slide3_header"),
                    text: t("slide3_text"),
                    accentColor: .greenAccent
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
                        .fill(currentTab == index ? Color.textPrimary : Color.textSecondary)
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
                HStack {
                    if currentTab == 4 {
                        NavigationLink(destination: {
                            CreateWalletWithPassphraseView()
                        }) {
                            BodyMText(t("advanced_setup"))
                        }
                    } else {
                        Button {
                            withAnimation {
                                currentTab = 4
                            }
                        } label: {
                            BodyMText(t("skip"))
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        OnboardingView()
    }
    .preferredColorScheme(.dark)
}
