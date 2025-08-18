import SwiftUI

struct AdvancedSettingsView: View {
    @StateObject private var suggestionsManager = SuggestionsManager.shared
    @State private var showingResetAlert = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // PAYMENTS Section
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BodyMText(
                            NSLocalizedString("settings__adv__section_payments", comment: ""),
                            textColor: .textSecondary
                        )
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                        Spacer()
                    }

                    // Maybe never implemented
                    // NavigationLink(destination: Text("Coming soon")) {
                    //     SettingsListLabel(
                    //         title: NSLocalizedString("settings__adv__address_type", comment: ""),
                    //         rightText: "Native Segwit"
                    //     )
                    // }

                    NavigationLink(value: Route.coinSelection) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__coin_selection", comment: "")
                        )
                    }

                    // NavigationLink(destination: Text("Coming soon")) {
                    //     SettingsListLabel(
                    //         title: NSLocalizedString("settings__adv__payment_preference", comment: "")
                    //     )
                    // }

                    // NavigationLink(destination: Text("Coming soon")) {
                    //     SettingsListLabel(
                    //         title: NSLocalizedString("settings__adv__gap_limit", comment: "")
                    //     )
                    // }
                }

                // NETWORKS Section
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BodyMText(
                            NSLocalizedString("settings__adv__section_networks", comment: ""),
                            textColor: .textSecondary
                        )
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                        Spacer()
                    }

                    NavigationLink(value: Route.connections) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__lightning_connections", comment: "")
                        )
                    }

                    NavigationLink(value: Route.node) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__lightning_node", comment: "")
                        )
                    }

                    NavigationLink(value: Route.electrumSettings) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__electrum_server", comment: "")
                        )
                    }

                    NavigationLink(destination: Text("Coming soon")) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__rgs_server", comment: "")
                        )
                    }
                }

                // OTHER Section
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BodyMText(
                            NSLocalizedString("settings__adv__section_other", comment: ""),
                            textColor: .textSecondary
                        )
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                        Spacer()
                    }

                    NavigationLink(value: Route.addressViewer) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__address_viewer", comment: "")
                        )
                    }

                    // SettingsListLabel(
                    //     title: NSLocalizedString("settings__adv__rescan", comment: ""),
                    //     rightIcon: nil
                    // )

                    Button(action: {
                        showingResetAlert = true
                    }) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__adv__suggestions_reset", comment: "")
                        )
                    }

                    // Add spacing at the bottom for the last section
                    Spacer()
                        .frame(height: 32)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(NSLocalizedString("settings__advanced_title", comment: ""))
        .alert(isPresented: $showingResetAlert) {
            Alert(
                title: Text(localizedString("settings__adv__reset_title")),
                message: Text(localizedString("settings__adv__reset_desc")),
                primaryButton: .destructive(Text(localizedString("settings__adv__reset_confirm"))) {
                    suggestionsManager.resetDismissed()
                },
                secondaryButton: .cancel()
            )
        }
    }
}
