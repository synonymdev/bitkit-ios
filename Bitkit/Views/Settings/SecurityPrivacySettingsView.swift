import LocalAuthentication
import SwiftUI

struct SecurityPrivacySettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var showPinCheckForLaunch = false
    @State private var showPinCheckForIdle = false
    @State private var showPinCheckForPayments = false
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return NSLocalizedString("security__bio_touch_id", comment: "")
        case .faceID:
            return NSLocalizedString("security__bio_face_id", comment: "")
        default:
            return NSLocalizedString("security__bio_face_id", comment: "") // Default to Face ID
        }
    }

    private var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Privacy Settings Section
                SettingsListLabel(
                    title: NSLocalizedString("settings__security__swipe_balance_to_hide", comment: ""),
                    toggle: $settings.swipeBalanceToHide
                )

                SettingsListLabel(
                    title: NSLocalizedString("settings__security__hide_balance_on_open", comment: ""),
                    toggle: $settings.hideBalanceOnOpen
                )

                SettingsListLabel(
                    title: NSLocalizedString("settings__security__clipboard", comment: ""),
                    toggle: $settings.readClipboard
                )

                SettingsListLabel(
                    title: NSLocalizedString("settings__security__warn_100", comment: ""),
                    toggle: $settings.warnWhenSendingOver100
                )

                // PIN Code Section
                if !settings.pinEnabled {
                    Button {
                        sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
                    } label: {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin", comment: ""),
                            rightText: NSLocalizedString("settings__security__pin_disabled", comment: "")
                        )
                    }
                } else {
                    NavigationLink(value: Route.disablePin) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin", comment: ""),
                            rightText: NSLocalizedString("settings__security__pin_enabled", comment: "")
                        )
                    }
                }

                if settings.pinEnabled {
                    NavigationLink(value: Route.changePin) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin_change", comment: "")
                        )
                    }

                    Button {
                        showPinCheckForLaunch = true
                    } label: {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin_launch", comment: ""),
                            rightIcon: nil,
                            toggle: Binding(
                                get: { settings.requirePinOnLaunch },
                                set: { _ in showPinCheckForLaunch = true }
                            )
                        )
                    }

                    Button {
                        showPinCheckForIdle = true
                    } label: {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin_idle", comment: ""),
                            rightIcon: nil,
                            toggle: Binding(
                                get: { settings.requirePinWhenIdle },
                                set: { _ in showPinCheckForIdle = true }
                            )
                        )
                    }

                    Button {
                        showPinCheckForPayments = true
                    } label: {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security__pin_payments", comment: ""),
                            rightIcon: nil,
                            toggle: Binding(
                                get: { settings.requirePinForPayments },
                                set: { _ in showPinCheckForPayments = true }
                            )
                        )
                    }

                    // Biometrics toggle with custom handling
                    SettingsListLabel(
                        title: localizedString(
                            "settings__security__use_bio", comment: "",
                            variables: ["biometryTypeName": biometryTypeName]
                        ),
                        toggle: Binding(
                            get: { settings.useBiometrics },
                            set: { newValue in
                                handleBiometricToggle(newValue)
                            }
                        )
                    )

                    // Footer text for Biometrics
                    BodySText(localizedString("settings__security__footer", variables: ["biometryTypeName": biometryTypeName]))
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(NSLocalizedString("settings__security__title", comment: ""))
        .navigationDestination(isPresented: $showPinCheckForLaunch) {
            PinCheckView(
                title: NSLocalizedString("security__pin_enter", comment: ""),
                explanation: "",
                onCancel: {},
                onPinVerified: { _ in
                    settings.requirePinOnLaunch.toggle()
                }
            )
        }
        .navigationDestination(isPresented: $showPinCheckForIdle) {
            PinCheckView(
                title: NSLocalizedString("security__pin_enter", comment: ""),
                explanation: "",
                onCancel: {},
                onPinVerified: { _ in
                    settings.requirePinWhenIdle.toggle()
                }
            )
        }
        .navigationDestination(isPresented: $showPinCheckForPayments) {
            PinCheckView(
                title: NSLocalizedString("security__pin_enter", comment: ""),
                explanation: "",
                onCancel: {},
                onPinVerified: { _ in
                    settings.requirePinForPayments.toggle()
                }
            )
        }
        .alert(
            NSLocalizedString("security__bio_error_title", comment: ""),
            isPresented: $showingBiometricError
        ) {
            Button(NSLocalizedString("common__ok", comment: "")) {
                // Error handled, user acknowledged
            }
        } message: {
            Text(biometricErrorMessage)
        }
    }

    private func handleBiometricToggle(_ newValue: Bool) {
        if !isBiometricAvailable {
            // Biometrics not available - show setup sheet
            sheets.showSheet(.security, data: SecurityConfig(showLaterButton: false))
            return
        }

        if newValue {
            // User wants to enable biometrics - request authentication
            requestBiometricPermission { success in
                if success {
                    settings.useBiometrics = true
                    Logger.debug("Biometric authentication enabled", context: "SecurityPrivacySettingsView")
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
                        Logger.debug("Biometric authentication disabled", context: "SecurityPrivacySettingsView")
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
        let reason = localizedString(
            "security__bio_confirm", comment: "",
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
            biometricErrorMessage = NSLocalizedString("security__bio_not_available", comment: "")
            showingBiometricError = true
        case LAError.biometryNotEnrolled.rawValue:
            biometricErrorMessage = NSLocalizedString("security__bio_not_available", comment: "")
            showingBiometricError = true
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just keep current state
            return
        default:
            biometricErrorMessage = localizedString(
                "security__bio_error_message", comment: "",
                variables: ["type": biometryTypeName]
            )
            showingBiometricError = true
        }

        Logger.error("Biometric authentication error: \(error)", context: "SecurityPrivacySettingsView")
    }
}

#Preview {
    SecurityPrivacySettingsView()
        .environmentObject(SheetViewModel())
        .environmentObject(SettingsViewModel())
        .preferredColorScheme(.dark)
}
