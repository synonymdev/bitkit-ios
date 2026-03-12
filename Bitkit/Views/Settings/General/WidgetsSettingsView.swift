import SwiftUI

struct WidgetsSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__widgets__nav_title"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsListLabel(
                        title: t("settings__widgets__showWidgets"),
                        toggle: $settings.showWidgets
                    )

                    SettingsListLabel(
                        title: t("settings__widgets__showWidgetTitles"),
                        toggle: $settings.showWidgetTitles
                    )
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationView {
        WidgetsSettingsView()
            .environmentObject(SettingsViewModel.shared)
    }
    .preferredColorScheme(.dark)
}
