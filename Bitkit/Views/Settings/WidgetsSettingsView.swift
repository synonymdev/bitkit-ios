import SwiftUI

struct WidgetsSettingsView: View {
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        ScrollView {
            SettingsListLabel(
                title: localizedString("settings__widgets__showWidgets"),
                toggle: $wallet.showWidgets
            )

            SettingsListLabel(
                title: localizedString("settings__widgets__showWidgetTitles"),
                toggle: $wallet.showWidgetTitles
            )
        }
        .navigationTitle(localizedString("settings__widgets__nav_title"))
    }
}

#Preview {
    NavigationView {
        WidgetsSettingsView()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
