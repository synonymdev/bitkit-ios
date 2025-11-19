import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @State private var showingResetAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__advanced_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // PAYMENTS Section
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("settings__adv__section_payments"))
                            .padding(.bottom, 8)

                        // Maybe never implemented
                        // NavigationLink(destination: Text("Coming soon")) {
                        //     SettingsListLabel(
                        //         title: t("settings__adv__address_type"),
                        //         rightText: "Native Segwit"
                        //     )
                        // }

                        NavigationLink(value: Route.coinSelection) {
                            SettingsListLabel(title: t("settings__adv__coin_selection"))
                        }
                        .accessibilityIdentifier("CoinSelectPreference")

                        // NavigationLink(destination: Text("Coming soon")) {
                        //     SettingsListLabel(title: t("settings__adv__payment_preference"))
                        // }

                        // NavigationLink(destination: Text("Coming soon")) {
                        //     SettingsListLabel(title: t("settings__adv__gap_limit"))
                        // }
                    }

                    // NETWORKS Section
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("settings__adv__section_networks"))
                            .padding(.top, 24)
                            .padding(.bottom, 8)

                        NavigationLink(value: Route.connections) {
                            SettingsListLabel(title: t("settings__adv__lightning_connections"))
                        }
                        .accessibilityIdentifier("Channels")

                        NavigationLink(value: Route.node) {
                            SettingsListLabel(title: t("settings__adv__lightning_node"))
                        }
                        .accessibilityIdentifier("LightningNodeInfo")

                        NavigationLink(value: Route.electrumSettings) {
                            SettingsListLabel(title: t("settings__adv__electrum_server"))
                        }
                        .accessibilityIdentifier("ElectrumConfig")

                        NavigationLink(value: Route.rgsSettings) {
                            SettingsListLabel(title: t("settings__adv__rgs_server"))
                        }
                        .accessibilityIdentifier("RGSServer")
                    }

                    // OTHER Section
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(
                            t("settings__adv__section_other")
                        )
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                        NavigationLink(value: Route.addressViewer) {
                            SettingsListLabel(title: t("settings__adv__address_viewer"))
                        }
                        .accessibilityIdentifier("AddressViewer")

                        // SettingsListLabel(title: t("settings__adv__rescan"), rightIcon: nil)

                        Button(action: {
                            showingResetAlert = true
                        }) {
                            SettingsListLabel(title: t("settings__adv__suggestions_reset"))
                        }
                        .accessibilityIdentifier("ResetSuggestions")

                        Spacer()
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .alert(t("settings__adv__reset_title"), isPresented: $showingResetAlert) {
            Button(t("settings__adv__reset_confirm"), role: .destructive) {
                suggestionsManager.resetDismissed()
                navigation.reset()
            }
            .accessibilityIdentifier("DialogConfirm")

            Button(t("common__dialog_cancel"), role: .cancel) {}
                .accessibilityIdentifier("DialogCancel")
        } message: {
            Text(t("settings__adv__reset_desc"))
        }
    }
}
