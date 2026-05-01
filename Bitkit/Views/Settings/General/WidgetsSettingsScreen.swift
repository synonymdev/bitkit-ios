import SwiftUI

struct WidgetsSettingsScreen: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @EnvironmentObject var widgets: WidgetsViewModel

    @State private var showWidgetsResetAlert = false
    @State private var showSuggestionsResetAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__widgets__nav_title"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader(t("settings__widgets__section_display"))

                    SettingsRow(
                        title: t("settings__widgets__showWidgets"),
                        toggle: $settings.showWidgets,
                        testIdentifier: "ShowWidgets"
                    )

                    SettingsRow(
                        title: t("settings__widgets__showWidgetTitles"),
                        toggle: $settings.showWidgetTitles,
                        testIdentifier: "ShowWidgetTitles"
                    )

                    SettingsSectionHeader(t("settings__widgets__section_reset"))
                        .padding(.top, 16)

                    Button(action: {
                        showWidgetsResetAlert = true
                    }) {
                        SettingsRow(
                            title: t("settings__widgets__reset_widgets"),
                            iconName: "arrow-counter-clockwise"
                        )
                    }
                    .accessibilityIdentifier("ResetWidgets")

                    Button(action: {
                        showSuggestionsResetAlert = true
                    }) {
                        SettingsRow(
                            title: t("settings__widgets__reset_suggestions"),
                            iconName: "arrow-counter-clockwise"
                        )
                    }
                    .accessibilityIdentifier("ResetSuggestions")
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
        .alert(t("settings__widgets__reset_widgets_dialog_title"), isPresented: $showWidgetsResetAlert) {
            Button(t("settings__adv__reset_confirm"), role: .destructive) {
                widgets.clearWidgets()
                navigation.reset()
            }
            .accessibilityIdentifier("DialogConfirm")

            Button(t("common__dialog_cancel"), role: .cancel) {}
                .accessibilityIdentifier("DialogCancel")
        } message: {
            Text(t("settings__widgets__reset_widgets_dialog_description"))
        }
        .alert(t("settings__adv__reset_title"), isPresented: $showSuggestionsResetAlert) {
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
