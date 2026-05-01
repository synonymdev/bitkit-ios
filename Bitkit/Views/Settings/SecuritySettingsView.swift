import LocalAuthentication
import SwiftUI

struct SecuritySettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var showPinCheckForPayments = false
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID: return t("security__bio_touch_id")
        case .faceID: return t("security__bio_face_id")
        default: return t("security__bio_face_id") // Default to Face ID
        }
    }

    private var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Backup section
                    SettingsSectionHeader(t("settings__security__section_backup"))

                    Button(action: {
                        sheets.showSheet(.backup, data: BackupConfig(view: .mnemonic))
                    }) {
                        SettingsRow(
                            title: t("settings__backup__wallet"),
                            iconName: "lock-key"
                        )
                    }
                    .accessibilityIdentifier("BackupWallet")

                    NavigationLink(value: Route.dataBackups) {
                        SettingsRow(
                            title: t("settings__backup__data"),
                            iconName: "database"
                        )
                    }
                    .accessibilityIdentifier("BackupSettings")

                    NavigationLink(value: Route.reset) {
                        SettingsRow(
                            title: t("settings__backup__reset"),
                            iconName: "arrow-counter-clockwise"
                        )
                    }
                    .accessibilityIdentifier("ResetAndRestore")

                    // Safety section
                    SettingsSectionHeader(t("settings__security__section_safety"))
                        .padding(.top, 16)

                    NavigationLink(value: Route.changePin) {
                        SettingsRow(
                            title: t("settings__security__pin"),
                            iconName: "shield",
                            rightText: settings.pinEnabled ? t("settings__security__pin_enabled") : t("settings__security__pin_disabled")
                        )
                    }
                    .accessibilityIdentifier("PINCode")

                    if settings.pinEnabled {
                        Button {
                            showPinCheckForPayments = true
                        } label: {
                            SettingsRow(
                                title: t("settings__security__pin_payments"),
                                iconName: "coins",
                                rightIcon: nil,
                                toggle: Binding(
                                    get: { settings.requirePinForPayments },
                                    set: { _ in showPinCheckForPayments = true }
                                )
                            )
                        }
                        .accessibilityIdentifier("EnablePinForPayments")

                        if isBiometricAvailable {
                            SettingsRow(
                                title: t("settings__security__use_bio", variables: ["biometryTypeName": biometryTypeName]),
                                iconName: "smiley",
                                toggle: Binding(
                                    get: { settings.useBiometrics },
                                    set: { newValue in
                                        handleBiometricToggle(newValue)
                                    }
                                ),
                                testIdentifier: "UseBiometryInstead"
                            )
                        }
                    }

                    SettingsRow(
                        title: t("settings__security__warn_100"),
                        iconName: "warning",
                        toggle: $settings.warnWhenSendingOver100,
                        testIdentifier: "SendAmountWarning"
                    )

                    // Privacy section
                    SettingsSectionHeader(t("settings__security__section_privacy"))
                        .padding(.top, 16)

                    SettingsRow(
                        title: t("settings__security__swipe_balance_to_hide"),
                        iconName: "hand-pointing",
                        toggle: $settings.swipeBalanceToHide,
                        testIdentifier: "SwipeBalanceToHide"
                    )

                    SettingsRow(
                        title: t("settings__security__hide_balance_on_open"),
                        iconName: "eye-slash",
                        toggle: $settings.hideBalanceOnOpen,
                        testIdentifier: "HideBalanceOnOpen"
                    )

                    SettingsRow(
                        title: t("settings__security__clipboard"),
                        iconName: "clipboard",
                        toggle: $settings.readClipboard,
                        testIdentifier: "AutoReadClipboard"
                    )
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationDestination(isPresented: $showPinCheckForPayments) {
            PinCheckView(
                title: t("security__pin_enter"),
                explanation: "",
                onCancel: {},
                onPinVerified: { _ in
                    settings.requirePinForPayments.toggle()
                }
            )
        }
        .alert(t("security__bio_error_title"), isPresented: $showingBiometricError) {
            Button(t("common__ok")) {
                // Error handled, user acknowledged
            }
        } message: {
            Text(biometricErrorMessage)
        }
    }

    private func handleBiometricToggle(_ newValue: Bool) {
        if newValue {
            // User wants to enable biometrics - request authentication
            requestBiometricPermission { success in
                if success {
                    settings.useBiometrics = true
                    Logger.debug("Biometric authentication enabled", context: "SecuritySettingsView")
                } else {
                    // Authentication failed - keep toggle off
                    // The toggle will automatically revert since we're not setting the value
                }
            }
        } else {
            // User wants to disable biometrics - confirm with biometric authentication if already enabled
            if settings.useBiometrics {
                requestBiometricPermission { success in
                    if success {
                        settings.useBiometrics = false
                        Logger.debug("Biometric authentication disabled", context: "SecuritySettingsView")
                    } else {
                        // Authentication failed - keep toggle on
                        // The toggle will automatically revert since we're not setting the value
                    }
                }
            } else {
                // Already disabled, just update the setting
                settings.useBiometrics = false
            }
        }
    }

    private func requestBiometricPermission(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?

        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            handleBiometricError(error)
            completion(false)
            return
        }

        // Request biometric authentication
        let reason = t(
            "security__bio_confirm",
            variables: ["biometricsName": biometryTypeName]
        )

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
            DispatchQueue.main.async {
                if success {
                    completion(true)
                } else {
                    if let error = authenticationError {
                        handleBiometricError(error)
                    }
                    completion(false)
                }
            }
        }
    }

    private func handleBiometricError(_ error: Error?) {
        guard let error else { return }

        let nsError = error as NSError

        switch nsError.code {
        case LAError.biometryNotAvailable.rawValue:
            biometricErrorMessage = t("security__bio_not_available")
            showingBiometricError = true
        case LAError.biometryNotEnrolled.rawValue:
            biometricErrorMessage = t("security__bio_not_available")
            showingBiometricError = true
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just keep current state
            return
        default:
            biometricErrorMessage = t(
                "security__bio_error_message",
                variables: ["type": biometryTypeName]
            )
            showingBiometricError = true
        }

        Logger.error("Biometric authentication error: \(error)", context: "SecuritySettingsView")
    }
}

#Preview {
    SecuritySettingsView()
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel.shared)
        .preferredColorScheme(.dark)
}
