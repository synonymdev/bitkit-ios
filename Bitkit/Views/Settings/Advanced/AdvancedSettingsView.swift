import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @AppStorage("showDevSettings") private var showDevSettings = Env.isDebug

    private var electrumRowRightText: String {
        let currentServerUrl = settings.electrumCurrentServer.fullUrl

        guard currentServerUrl != Env.electrumServerUrl else {
            return t("settings__adv__electrum_auto")
        }

        return settings.electrumCurrentServer.host.replacingOccurrences(of: "://", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Debug Section
                    if showDevSettings {
                        SettingsSectionHeader(t("settings__adv__section_debug"))

                        NavigationLink(value: Route.devSettings) {
                            SettingsRow(
                                title: t("settings__dev_title"),
                                iconName: "game-controller"
                            )
                        }
                        .padding(.bottom, 16)
                        .accessibilityIdentifier("DevSettings")
                    }

                    // Payments section
                    SettingsSectionHeader(t("settings__adv__section_payments"))

                    NavigationLink(value: Route.addressTypePreference) {
                        SettingsRow(
                            title: t("settings__adv__address_type_title"),
                            iconName: "list-dashes",
                            rightText: settings.selectedAddressType.localizedTitle
                        )
                    }
                    .accessibilityIdentifier("AddressTypePreference")

                    NavigationLink(value: Route.coinSelection) {
                        SettingsRow(
                            title: t("settings__adv__coin_selection"),
                            iconName: "coins",
                            rightText: settings.coinSelectionMethod.localizedTitle
                        )
                    }
                    .accessibilityIdentifier("CoinSelectPreference")

                    NavigationLink(value: Route.addressViewer) {
                        SettingsRow(
                            title: t("settings__adv__address_viewer"),
                            iconName: "eye"
                        )
                    }
                    .accessibilityIdentifier("AddressViewer")

                    // Networks section
                    SettingsSectionHeader(t("settings__adv__section_networks"))
                        .padding(.top, 16)

                    NavigationLink(value: Route.connections) {
                        SettingsRow(
                            title: t("settings__adv__lightning_connections"),
                            iconName: "bolt-hollow",
                            rightText: String(wallet.channels?.count ?? 0)
                        )
                    }
                    .accessibilityIdentifier("Channels")

                    NavigationLink(value: Route.node) {
                        SettingsRow(
                            title: t("settings__adv__lightning_node"),
                            iconName: "git-branch",
                            rightText: wallet.nodeId?.ellipsis(maxLength: 5, style: .end)
                        )
                    }
                    .accessibilityIdentifier("LightningNodeInfo")

                    NavigationLink(value: Route.electrumSettings) {
                        SettingsRow(
                            title: t("settings__adv__electrum_server"),
                            iconName: "hard-drives",
                            rightText: electrumRowRightText
                        )
                    }
                    .accessibilityIdentifier("ElectrumConfig")

                    NavigationLink(value: Route.rgsSettings) {
                        SettingsRow(
                            title: t("settings__adv__rgs_server"),
                            iconName: "broadcast"
                        )
                    }
                    .accessibilityIdentifier("RGSServer")
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
    }
}
