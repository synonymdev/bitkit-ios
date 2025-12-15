import SwiftUI

struct MainSettings: View {
    @EnvironmentObject private var app: AppViewModel

    @AppStorage("showDevSettings") private var showDevSettings = Env.isDebug
    @State private var cogTapCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__settings"))

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink(value: Route.generalSettings) {
                            SettingsListLabel(
                                title: t("settings__general_title"),
                                iconName: "gear-six"
                            )
                        }
                        .accessibilityIdentifier("GeneralSettings")

                        NavigationLink(value: Route.securitySettings) {
                            SettingsListLabel(
                                title: t("settings__security_title"),
                                iconName: "shield"
                            )
                        }
                        .accessibilityIdentifier("SecuritySettings")

                        NavigationLink(value: Route.backupSettings) {
                            SettingsListLabel(
                                title: t("settings__backup_title"),
                                iconName: "rewind"
                            )
                        }
                        .accessibilityIdentifier("BackupSettings")

                        NavigationLink(value: Route.advancedSettings) {
                            SettingsListLabel(
                                title: t("settings__advanced_title"),
                                iconName: "sliders"
                            )
                        }
                        .accessibilityIdentifier("AdvancedSettings")

                        NavigationLink(value: Route.paykitDashboard) {
                            SettingsListLabel(
                                title: "Paykit",
                                iconName: "creditcard"
                            )
                        }
                        .accessibilityIdentifier("PaykitSettings")

                        NavigationLink(value: Route.support) {
                            SettingsListLabel(
                                title: t("settings__support_title"),
                                iconName: "chat"
                            )
                        }
                        .accessibilityIdentifier("Support")

                        NavigationLink(value: Route.about) {
                            SettingsListLabel(
                                title: t("settings__about_title"),
                                iconName: "info"
                            )
                        }
                        .accessibilityIdentifier("About")

                        if showDevSettings {
                            NavigationLink(value: Route.devSettings) {
                                SettingsListLabel(
                                    title: t("settings__dev_title"),
                                    iconName: "game-controller"
                                )
                            }
                            .accessibilityIdentifier("DevSettings")
                        }

                        Spacer()

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
                                        title: t(showDevSettings ? "settings__dev_enabled_title" : "settings__dev_disabled_title"),
                                        description: t(showDevSettings ? "settings__dev_enabled_message" : "settings__dev_disabled_message")
                                    )
                                }
                            }
                            .accessibilityIdentifier("DevOptions")

                        Spacer()
                    }
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}
