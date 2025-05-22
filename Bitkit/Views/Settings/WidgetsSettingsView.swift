import SwiftUI

struct WidgetsSettingsView: View {
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        List {
            Toggle(localizedString("settings__widgets__showWidgets"), isOn: $wallet.showWidgets)
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))

            Toggle(localizedString("settings__widgets__showWidgetTitles"), isOn: $wallet.showWidgetTitles)
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
        }
        .navigationBarTitle(localizedString("settings__widgets__nav_title"))
    }
}

#Preview {
    NavigationView {
        WidgetsSettingsView()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
