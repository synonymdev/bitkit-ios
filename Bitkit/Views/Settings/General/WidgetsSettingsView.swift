import SwiftUI

struct WidgetsSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsListLabel(
                    title: localizedString("settings__widgets__showWidgets"),
                    toggle: $settings.showWidgets
                )

                SettingsListLabel(
                    title: localizedString("settings__widgets__showWidgetTitles"),
                    toggle: $settings.showWidgetTitles
                )
            }
            .padding(.horizontal, 16)
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
