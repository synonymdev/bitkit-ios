import SwiftUI

struct WidgetsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("widgets__nav_title"))

            VStack(spacing: 0) {
                VStack {
                    Spacer()
                    Image("puzzle")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 14) {
                    DisplayText(t("widgets__onboarding__title"), accentColor: .brandAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    BodyMText(t("widgets__onboarding__description"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 16) {
                    CustomButton(
                        title: t("widgets__onboarding__view_organize"),
                        variant: .secondary,
                        size: .large,
                        shouldExpand: true,
                        action: onViewOrganize
                    )
                    .accessibilityIdentifier("WidgetsOnboardingViewOrganize")

                    CustomButton(
                        title: t("widgets__add"),
                        variant: .primary,
                        size: .large,
                        shouldExpand: true,
                        action: onAddWidget
                    )
                    .accessibilityIdentifier("WidgetsOnboardingAddWidget")
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
        .navigationBarHidden(true)
        .accessibilityIdentifier("WidgetsOnboarding")
    }

    private func onViewOrganize() {
        app.hasSeenWidgetsIntro = true
        navigation.reset()
        // When widgets are disabled the home widgets page is hidden, so there's nothing to
        // organize — open the widgets sheet instead (matches Android `onViewOrganize`).
        if settings.showWidgets {
            app.requestedHomePage = 1
        } else {
            sheets.showSheet(.widgets, data: WidgetsConfig(initialRoute: .list))
        }
    }

    private func onAddWidget() {
        app.hasSeenWidgetsIntro = true
        navigation.reset()
        sheets.showSheet(.widgets, data: WidgetsConfig(initialRoute: .list))
    }
}

#Preview {
    NavigationStack {
        WidgetsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(SheetViewModel())
    }
    .preferredColorScheme(.dark)
}
