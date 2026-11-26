import SwiftUI

struct WalletConnectionRecoveryView: View {
    let onBack: () -> Void
    let onRetry: () async -> Void
    @ObservedObject var recovery = ConnectionRecoveryService.shared
    @State private var editor: ConnectionRecoveryService.Editor
    @State private var electrum = ""
    @State private var rgs = ""
    @State private var saved = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    init(editor: ConnectionRecoveryService.Editor, onBack: @escaping () -> Void,
         onRetry: @escaping () async -> Void, recovery: ConnectionRecoveryService)
    {
        self.onBack = onBack
        self.onRetry = onRetry
        self.recovery = recovery
        _editor = State(initialValue: editor)
        _electrum = State(initialValue: editor.electrum.fullUrl)
        _rgs = State(initialValue: editor.rgs)
    }

    private var canEdit: Bool {
        !recovery.isBusy && recovery.isCurrent(editor)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(t("common__back"), action: onBack).accessibilityIdentifier("NavigationBack")
                Spacer()
                BodyMText(t("onboarding__connection_settings"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BodyMText(t("settings__adv__electrum_server"))
                    TextField("ssl://host:50002", text: $electrum)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("RecoveryElectrumInput")
                        .disabled(!canEdit)
                    CustomButton(title: t("settings__es__button_reset"), variant: .secondary,
                                 isDisabled: !canEdit)
                    {
                        electrum = ElectrumConfigService().getDefaultServer().fullUrl
                    }.accessibilityIdentifier("RecoveryElectrumReset")
                    CustomButton(title: t("common__save"), isDisabled: !canEdit) {
                        saveElectrum()
                    }.accessibilityIdentifier("RecoveryElectrumSave")

                    BodyMText(t("settings__rgs__server_url"))
                    TextField("https://host", text: $rgs)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("RecoveryRgsInput")
                        .disabled(!canEdit)
                    CustomButton(title: t("settings__es__button_reset"), variant: .secondary,
                                 isDisabled: !canEdit)
                    {
                        rgs = RgsConfigService().getDefaultServerUrl()
                    }.accessibilityIdentifier("RecoveryRgsReset")
                    CustomButton(title: t("common__save"), isDisabled: !canEdit) {
                        saveRgs()
                    }.accessibilityIdentifier("RecoveryRgsSave")

                    if saved {
                        BodyMText(t("onboarding__connection_saved")).accessibilityIdentifier("RecoverySaved")
                    }
                    if let error {
                        BodyMText(error, textColor: .redAccent).accessibilityIdentifier("RecoveryError")
                    }
                    CustomButton(title: t("common__try_again"), isDisabled: !canEdit, isLoading: recovery.isBusy) {
                        work = Task {
                            guard canEdit else { return }
                            await onRetry()
                        }
                    }.accessibilityIdentifier("RecoveryRetry")
                }
            }
        }
        .padding(16)
        .bottomSafeAreaPadding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WalletConnectionRecovery")
        .onDisappear { work?.cancel() }
        .onChange(of: electrum) { saved = false }
        .onChange(of: rgs) { saved = false }
    }

    private func saveElectrum() {
        let input = electrum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: input),
              let host = components.host, let port = components.port,
              let scheme = components.scheme, ["tcp", "ssl"].contains(scheme),
              components.user == nil, components.password == nil, components.path.isEmpty,
              components.query == nil, components.fragment == nil,
              SettingsViewModel.shared.validateElectrumInput(host: host, port: String(port)) == nil
        else {
            error = t("settings__es__server_error_description")
            return
        }
        let server = ElectrumServer(host: host, port: port, protocolType: scheme == "ssl" ? .ssl : .tcp)
        save { owner in try await recovery.save(editor: owner, electrum: server) }
    }

    private func saveRgs() {
        let input = rgs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty || RgsConfigService().getDefaultServerUrl().isEmpty,
              SettingsViewModel.shared.isValidRgsUrl(input)
        else {
            error = t("settings__rgs__server_error_description")
            return
        }
        save { owner in
            try await recovery.save(editor: owner, rgs: input) {
                if !input.isEmpty, await !SettingsViewModel.shared.isRgsEndpointReachable(input) {
                    throw AppError(message: t("settings__rgs__server_error_description"), debugMessage: nil)
                }
            }
        }
    }

    private func save(_ action: @escaping (ConnectionRecoveryService.Editor) async throws -> Void) {
        guard canEdit else { return }
        let editor = editor
        error = nil
        saved = false
        work = Task {
            do {
                try await action(editor)
                guard !Task.isCancelled, recovery.isCurrent(editor) else { return }
                self.editor = try recovery.editor()
                saved = true
            } catch {
                guard !Task.isCancelled, recovery.isCurrentLifecycle(editor.generation) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
