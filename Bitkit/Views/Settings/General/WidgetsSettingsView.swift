import SwiftUI

struct WidgetsSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__widgets__nav_title"))

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
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationView {
        WidgetsSettingsView()
            .environmentObject(SettingsViewModel())
    }
    .preferredColorScheme(.dark)
}
