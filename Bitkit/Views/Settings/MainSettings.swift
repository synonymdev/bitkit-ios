import SwiftUI

struct MainSettings: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    @AppStorage("showDevSettings") private var showDevSettings = Env.isDebug
    @State private var cogTapCount = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink(value: Route.generalSettings) {
                        SettingsListLabel(
                            title: localizedString("settings__general_title"),
                            iconName: "gear-six"
                        )
                    }

                    NavigationLink(value: Route.securitySettings) {
                        SettingsListLabel(
                            title: localizedString("settings__security_title"),
                            iconName: "shield"
                        )
                    }

                    NavigationLink(value: Route.backupSettings) {
                        SettingsListLabel(
                            title: localizedString("settings__backup_title"),
                            iconName: "rewind"
                        )
                    }

                    NavigationLink(value: Route.advancedSettings) {
                        SettingsListLabel(
                            title: localizedString("settings__advanced_title"),
                            iconName: "sliders"
                        )
                    }

                    NavigationLink(value: Route.support) {
                        SettingsListLabel(
                            title: localizedString("settings__support_title"),
                            iconName: "chat"
                        )
                    }

                    NavigationLink(value: Route.about) {
                        SettingsListLabel(
                            title: localizedString("settings__about_title"),
                            iconName: "info"
                        )
                    }

                    if showDevSettings {
                        NavigationLink(value: Route.devSettings) {
                            SettingsListLabel(
                                title: localizedString("settings__dev_title"),
                                iconName: "game-controller"
                            )
                        }
                    }

                    Spacer()
                        .frame(minHeight: 32)

                    Image("cog")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onTapGesture {
                            cogTapCount += 1

                            // Toggle dev settings every 5 taps
                            if cogTapCount >= 5 {
                                showDevSettings.toggle()
                                cogTapCount = 0

                                app.toast(
                                    type: .success,
                                    title: localizedString(showDevSettings ? "settings__dev_enabled_title" : "settings__dev_disabled_title"),
                                    description: localizedString(showDevSettings ? "settings__dev_enabled_message" : "settings__dev_disabled_message")
                                )
                            }
                        }

                    Spacer()
                        .frame(minHeight: 32)
                }
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(localizedString("settings__settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
