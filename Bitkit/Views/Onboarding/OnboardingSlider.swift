import SwiftUI

private struct OnboardingToolbar: View {
    let currentTab: Int
    let onSkip: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack {
                Spacer()
                CustomButton(
                    title: t("onboarding__advanced_setup"),
                    variant: .secondary,
                    size: .small,
                    destination: CreateWalletWithPassphraseView()
                )
                .accessibilityIdentifier("Passphrase")
            }
            .opacity(currentTab == 3 ? 1 : 0)

            HStack {
                Spacer()
                CustomButton(title: t("onboarding__skip"), variant: .secondary, size: .small) {
                    onSkip()
                }
                .accessibilityIdentifier("SkipButton")
            }
            .opacity(currentTab == 3 ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.3), value: currentTab)
    }
}

private struct Dots: View {
    var currentTab: Int

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ForEach(0 ..< 4) { index in
                    Circle()
                        .fill(currentTab == index ? Color.textPrimary : Color.white32)
                        .frame(width: 8, height: 8)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentTab)
        }
    }
}

struct OnboardingSlider: View {
    @EnvironmentObject var app: AppViewModel
    @State var currentTab = 0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                OnboardingToolbar(currentTab: currentTab) {
                    withAnimation {
                        currentTab = 3
                    }
                }
                .padding(.horizontal, 16)

                TabView(selection: $currentTab) {
                    OnboardingTab(
                        imageName: "keyring",
                        title: t("onboarding__slide0_header"),
                        text: tTodo("Bitkit hands you the keys to control your money, profile, and contacts. Take charge and become borderless."),
                        accentColor: .blueAccent
                    )
                    .tag(0)
                    .accessibilityIdentifier("Slide0")

                    OnboardingTab(
                        imageName: "lightning",
                        title: t("onboarding__slide1_header"),
                        text: tTodo("Enjoy instant and cheap payments with friends, family, and merchants on the Lightning Network."),
                        disclaimerText: GeoService.shared.isGeoBlocked ? t("onboarding__slide1_note") : nil,
                        accentColor: .purpleAccent
                    )
                    .tag(1)
                    .accessibilityIdentifier("Slide1")

                    OnboardingTab(
                        imageName: "shield-figure",
                        title: t("onboarding__slide3_header"),
                        text: tTodo(
                            "Your money, your privacy. Swipe to hide your balance and spend more privately, with no data tracking and zero KYC."
                        ),
                        accentColor: .greenAccent
                    )
                    .tag(2)
                    .accessibilityIdentifier("Slide2")

                    CreateWalletView()
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            if currentTab != 3 {
                Dots(currentTab: currentTab)
            }
        }
        .navigationBarHidden(true)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        OnboardingSlider()
    }
    .preferredColorScheme(.dark)
}
