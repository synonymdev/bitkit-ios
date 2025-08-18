import SwiftUI

struct OnboardingToolbar: View {
    let currentTab: Int
    let onSkip: () -> Void

    // TODO: use Button .tertiary

    var body: some View {
        ZStack(alignment: .trailing) {
            NavigationLink(destination: {
                CreateWalletWithPassphraseView()
            }) {
                HStack {
                    Spacer()
                    BodyMSBText(t("onboarding__advanced_setup"), textColor: .secondary)
                }
            }
            .opacity(currentTab == 4 ? 1 : 0)

            Button {
                onSkip()
            } label: {
                HStack {
                    Spacer()
                    BodyMSBText(t("onboarding__skip"), textColor: .secondary)
                }
            }
            .opacity(currentTab == 4 ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.3), value: currentTab)
    }
}

struct Dots: View {
    @Binding var currentTab: Int

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ForEach(0 ..< 5) { index in
                    Circle()
                        .fill(currentTab == index ? Color.textPrimary : Color.gray2)
                        .frame(width: 7, height: 7)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentTab)
            .padding(.bottom, 26)
        }
    }
}

struct OnboardingSlider: View {
    @EnvironmentObject var app: AppViewModel
    @State var currentTab = 0

    var body: some View {
        ZStack {
            VStack {
                TabView(selection: $currentTab) {
                    // Slide 0
                    OnboardingTab(
                        imageName: "keyring",
                        title: t("onboarding__slide0_header"),
                        text: t("onboarding__slide0_text"),
                        accentColor: .blueAccent
                    )
                    .tag(0)

                    // Slide 1
                    OnboardingTab(
                        imageName: "lightning",
                        title: t("onboarding__slide1_header"),
                        text: t("onboarding__slide1_text"),
                        disclaimerText: app.isGeoBlocked == true ? t("onboarding__slide1_note") : nil,
                        accentColor: .purpleAccent
                    )
                    .tag(1)

                    // Slide 2
                    OnboardingTab(
                        imageName: "spark",
                        title: t("onboarding__slide2_header"),
                        text: t("onboarding__slide2_text"),
                        accentColor: .yellowAccent
                    )
                    .tag(2)

                    // Slide 3
                    OnboardingTab(
                        imageName: "shield-figure",
                        title: t("onboarding__slide3_header"),
                        text: t("onboarding__slide3_text"),
                        accentColor: .greenAccent
                    )
                    .tag(3)

                    // Slide 4
                    CreateWalletView()
                        .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            if currentTab != 4 {
                Dots(currentTab: $currentTab)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .bottomSafeAreaPadding()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                OnboardingToolbar(currentTab: currentTab) {
                    withAnimation {
                        currentTab = 4
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        OnboardingSlider()
    }
    .preferredColorScheme(.dark)
}
