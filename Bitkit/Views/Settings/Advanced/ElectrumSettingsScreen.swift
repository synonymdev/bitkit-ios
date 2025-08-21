import SwiftUI

struct ElectrumSettingsScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Connection Status Section
                    VStack(alignment: .leading, spacing: 4) {
                        BodyMText(t("settings__es__connected_to"))

                        if settings.electrumIsLoading {
                            ProgressView()
                        } else {
                            if settings.electrumIsConnected {
                                BodyMText(settings.electrumCurrentServer.url, textColor: .greenAccent)
                            } else {
                                BodyMText(t("settings__es__disconnected"), textColor: .redAccent)
                            }
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 32)

                    // Host Input Section
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText(t("settings__es__host"))
                        TextField("127.0.0.1", text: $settings.electrumHost)
                            .focused($isTextFieldFocused)
                            .autocapitalization(.none)
                            .autocorrectionDisabled(true)
                            .submitLabel(.done)
                            .onSubmit {
                                isTextFieldFocused = false
                            }
                    }
                    .padding(.bottom, 16)

                    // Port Input Section
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText(t("settings__es__port"))
                        TextField("50001", text: $settings.electrumPort)
                            .focused($isTextFieldFocused)
                            .keyboardType(.numberPad)
                    }
                    .padding(.bottom, 27)

                    // Protocol Selection Section
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText(t("settings__es__protocol"))
                        RadioGroup(
                            options: [
                                RadioOption(title: "TCP", value: ElectrumProtocol.tcp),
                                RadioOption(title: "TLS", value: ElectrumProtocol.ssl),
                            ],
                            selectedValue: $settings.electrumSelectedProtocol,
                        )
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        CustomButton(title: t("settings__es__button_reset"), variant: .secondary) {
                            onReset()
                        }

                        CustomButton(
                            title: t("settings__es__button_connect"),
                            isDisabled: !settings.electrumCanConnect,
                            isLoading: settings.electrumIsLoading
                        ) {
                            onConnect()
                        }
                    }
                    .padding(.bottom, isTextFieldFocused ? 16 : 0)
                }
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
            .navigationTitle(t("settings__adv__electrum_server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        navigation.navigate(.scanner)
                    }) {
                        Image("scan")
                            .resizable()
                            .foregroundColor(.textPrimary)
                            .frame(width: 32, height: 32)
                    }
                }
            }
        }
        .onAppear {
            settings.loadElectrumSettings()
        }
    }

    private func onConnect() {
        Task {
            let result = await settings.connectToElectrumServer()
            showToast(result.success, result.host, result.port, result.errorMessage)
        }
    }

    private func onReset() {
        Task {
            let result = await settings.resetElectrumToDefault()
            showToast(result.success, result.host, result.port, result.errorMessage)
        }
    }

    private func showToast(_ success: Bool, _ host: String, _ port: String, _ errorMessage: String?) {
        if success {
            app.toast(
                type: .success,
                title: t("settings__es__server_updated_title"),
                description: t("settings__es__server_updated_message", variables: ["host": host, "port": port])
            )
        } else {
            app.toast(
                type: .warning,
                title: t("settings__es__error_peer"),
                description: errorMessage ?? t("settings__es__server_error_description")
            )
        }
    }
}
