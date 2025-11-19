import SwiftUI

struct RgsSettingsScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__adv__rgs_server"))
                .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Connection Status Section
                        VStack(alignment: .leading, spacing: 4) {
                            BodyMText(t("settings__es__connected_to"))
                            BodyMText(settings.rgsConfigService.getCurrentServerUrl(), textColor: .greenAccent)
                                .accessibilityIdentifier("ConnectedUrl")
                        }
                        .padding(.bottom, 32)

                        // Server URL Input Section
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("settings__rgs__server_url"))
                            TextField(settings.rgsConfigService.getCurrentServerUrl(), text: $settings.rgsServerUrl)
                                .focused($isTextFieldFocused)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                                .submitLabel(.done)
                                .onSubmit {
                                    isTextFieldFocused = false
                                }
                                .accessibilityIdentifier("RGSUrl")
                        }

                        Spacer()

                        HStack(spacing: 16) {
                            CustomButton(
                                title: t("settings__es__button_reset"),
                                variant: .secondary,
                                isDisabled: !settings.rgsCanReset
                            ) {
                                onReset()
                            }
                            .accessibilityIdentifier("ResetToDefault")

                            CustomButton(
                                title: t("settings__rgs__button_connect"),
                                isDisabled: !settings.rgsCanConnect,
                                isLoading: settings.rgsIsLoading
                            ) {
                                onConnect()
                            }
                            .accessibilityIdentifier("ConnectToHost")
                        }
                        .padding(.bottom, isTextFieldFocused ? 16 : 0)
                    }
                    .frame(minHeight: geometry.size.height)
                    .bottomSafeAreaPadding()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .onAppear {
            settings.loadRgsSettings()
        }
    }

    private func onConnect() {
        Task {
            let result = await settings.connectToRgsServer()
            showToast(result.success, result.url, result.errorMessage)
        }
    }

    private func onReset() {
        Task {
            let result = await settings.resetRgsToDefault()
            showToast(result.success, result.url, result.errorMessage)
        }
    }

    private func showToast(_ success: Bool, _ url: String, _ errorMessage: String?) {
        if success {
            app.toast(
                type: .success,
                title: t("settings__rgs__update_success_title"),
                description: t("settings__rgs__update_success_description")
            )
        } else {
            app.toast(
                type: .warning,
                title: tTodo("settings__rgs__error_peer"),
                description: errorMessage ?? tTodo("settings__rgs__server_error_description")
            )
        }
    }
}
