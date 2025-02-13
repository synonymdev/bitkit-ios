import SwiftUI

struct OnboardingView: View {
    @State var currentTab = 0

    var body: some View {
        VStack {
            TabView(selection: $currentTab) {
                // Slide 0
                OnboardingTab(
                    imageName: "keyring",
                    title: NSLocalizedString("onboarding__slide0_header", comment: ""),
                    text: NSLocalizedString("onboarding__slide0_text", comment: ""),
                    accentColor: .blueAccent
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(0)

                // Slide 1
                OnboardingTab(
                    imageName: "lightning",
                    title: NSLocalizedString("onboarding__slide1_header", comment: ""),
                    text: NSLocalizedString("onboarding__slide1_text", comment: ""),
                    disclaimerText: NSLocalizedString("onboarding__slide1_note", comment: ""),
                    accentColor: .purpleAccent
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(1)

                // Slide 2
                OnboardingTab(
                    imageName: "spark",
                    title: NSLocalizedString("onboarding__slide2_header", comment: ""),
                    text: NSLocalizedString("onboarding__slide2_text", comment: ""),
                    accentColor: .yellowAccent
                )
                .padding(.bottom, 30)
                .padding(.horizontal, 32)
                .tag(2)

                // Slide 3
                OnboardingTab(
                    imageName: "shield",
                    title: NSLocalizedString("onboarding__slide3_header", comment: ""),
                    text: NSLocalizedString("onboarding__slide3_text", comment: ""),
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
                            BodyMText(NSLocalizedString("onboarding__advanced_setup", comment: ""))
                        }
                    } else {
                        Button {
                            withAnimation {
                                currentTab = 4
                            }
                        } label: {
                            BodyMText(NSLocalizedString("onboarding__skip", comment: ""))
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
