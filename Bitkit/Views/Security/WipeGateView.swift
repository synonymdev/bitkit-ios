import SwiftUI

/// Shown instead of the whole app while a wipe is pending or the lockout state cannot be verified. It offers no PIN pad, no
/// biometrics and no navigation: only the wipe's progress, Retry, Export logs and, while blocked, a reset.
struct WipeGateView: View {
    @EnvironmentObject private var app: AppViewModel
    @ObservedObject var coordinator: WipeCoordinator

    @State private var isShowingResetConfirmation = false

    private var isRunning: Bool {
        if case .failed = coordinator.progress { false } else { coordinator.gate == .wiping }
    }

    private var title: String {
        coordinator.gate == .blocked ? t("security__wipe_gate_blocked_title") : t("security__wipe_gate_title")
    }

    private var message: String {
        if coordinator.gate == .blocked {
            return t("security__wipe_gate_blocked_text")
        }
        return isRunning ? t("security__wipe_gate_text") : t("security__wipe_gate_failed")
    }

    private var stepLabel: String? {
        guard coordinator.gate == .wiping else { return nil }
        let step: WipeStep? = switch coordinator.progress {
        case let .running(step): step
        case let .failed(step): step
        case .idle: nil
        }
        guard let step, let index = WipeStep.allCases.firstIndex(of: step) else { return nil }
        return t("security__wipe_gate_step", variables: ["step": "\(index + 1)", "total": "\(WipeStep.allCases.count)"])
    }

    var body: some View {
        VStack(spacing: 0) {
            DisplayText(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .padding(.bottom, 14)

            BodyMText(message)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            if isRunning {
                ActivityIndicator(size: 32)
            }

            if let stepLabel {
                CaptionText(stepLabel)
                    .padding(.top, 16)
                    .accessibilityIdentifier("WipeGateStep")
            }

            Spacer()

            if !isRunning {
                VStack(spacing: 16) {
                    CustomButton(title: t("common__retry")) {
                        coordinator.retry()
                    }
                    .accessibilityIdentifier("WipeGateRetry")

                    CustomButton(title: t("lightning__conn_button_export_logs"), variant: .secondary) {
                        if !LogService.shared.shareLogs() {
                            app.toast(type: .error, title: t("lightning__error_logs"))
                        }
                    }
                    .accessibilityIdentifier("WipeGateExportLogs")

                    if coordinator.gate == .blocked {
                        CustomButton(title: t("security__reset_button_reset"), variant: .tertiary) {
                            isShowingResetConfirmation = true
                        }
                        .accessibilityIdentifier("WipeGateReset")
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WipeGate")
        .alert(t("security__reset_dialog_title"), isPresented: $isShowingResetConfirmation) {
            Button(t("common__cancel"), role: .cancel) {}
            Button(t("security__reset_confirm"), role: .destructive) {
                resetWallet()
            }
        } message: {
            Text(t("security__reset_dialog_desc"))
        }
        .onChange(of: isRunning, initial: true) { _, isRunning in
            UIApplication.shared.isIdleTimerDisabled = isRunning
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func resetWallet() {
        do {
            try coordinator.resetFromBlockedGate()
        } catch {
            Logger.error("Failed to start a reset from the blocked gate: \(error)", context: "WipeGateView")
            app.toast(type: .error, title: t("common__error"), description: t("security__wipe_not_started"))
        }
    }
}
