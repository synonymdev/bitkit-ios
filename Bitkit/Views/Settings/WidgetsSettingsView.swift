import SwiftUI

struct WidgetsSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        ScrollView {
            SettingsListLabel(
                title: localizedString("settings__widgets__showWidgets"),
                toggle: $settings.showWidgets
            )

            SettingsListLabel(
                title: localizedString("settings__widgets__showWidgetTitles"),
                toggle: $settings.showWidgetTitles
            )
        }
        .navigationTitle(localizedString("settings__widgets__nav_title"))
    }
}

#Preview {
    NavigationView {
        WidgetsSettingsView()
            .environmentObject(SettingsViewModel())
    }
    .preferredColorScheme(.dark)
}
