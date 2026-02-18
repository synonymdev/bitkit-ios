import LDKNode
import SwiftUI

struct AddressTypeOption: View {
    let addressType: AddressScriptType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        BodyMText("\(addressType.localizedTitle) \(addressType.example)", textColor: .textPrimary)
                        BodySText(addressType.localizedDescription)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    if isSelected {
                        Image("checkmark")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(.brandAccent)
                    }
                }
                .frame(height: 51)
                .padding(.bottom, 16)

                Divider()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier(addressType.testId)
    }
}

struct MonitoredAddressTypeToggle: View {
    let addressType: AddressScriptType
    let isMonitored: Bool
    let isSelectedType: Bool
    let onToggle: (Bool) -> Void

    private var toggleId: String {
        "MonitorToggle-\(addressType.testId)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if !isSelectedType {
                    onToggle(!isMonitored)
                }
            }) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        BodyMText("\(addressType.localizedTitle) \(addressType.shortExample)", textColor: .textPrimary)
                        if isSelectedType {
                            BodySText(t("settings__adv__addr_type_currently_selected"), textColor: .textSecondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: .constant(isMonitored))
                        .tint(.brandAccent)
                        .labelsHidden()
                        .allowsHitTesting(false)
                }
                .frame(minHeight: 51)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSelectedType)
            .opacity(isSelectedType ? 0.5 : 1.0)
            .accessibilityIdentifier(toggleId)

            Divider()
        }
    }
}

struct AddressTypePreferenceView: View {
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel

    @AppStorage("showDevSettings") private var showDevSettings = Env.isDebug

    @State private var showMonitoredTypesNote = false
    @State private var showLoadingView = false
    @State private var loadingAddressType: AddressScriptType?
    @State private var isMonitoringChange = false
    @State private var loadingTask: Task<Void, Never>?

    private let timeoutSeconds: UInt64 = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__adv__address_type"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("settings__adv__address_type"))
                            .padding(.bottom, 8)

                        VStack(spacing: 0) {
                            ForEach(AddressScriptType.allAddressTypes, id: \.self) { addressType in
                                AddressTypeOption(
                                    addressType: addressType,
                                    isSelected: settingsViewModel.selectedAddressType == addressType
                                ) {
                                    guard settingsViewModel.selectedAddressType != addressType else { return }

                                    loadingAddressType = addressType
                                    isMonitoringChange = false
                                    showLoadingView = true

                                    loadingTask = Task {
                                        var success = false
                                        let didTimeout = await withTimeout(seconds: timeoutSeconds) {
                                            success = await settingsViewModel.updateAddressType(addressType, wallet: wallet)
                                        }

                                        showLoadingView = false

                                        if didTimeout {
                                            app.toast(
                                                type: .error,
                                                title: t("settings__adv__addr_type_timeout_title"),
                                                description: t("settings__adv__addr_type_timeout_desc")
                                            )
                                        } else if success {
                                            Haptics.notify(.success)
                                            navigation.reset()
                                            app.toast(
                                                type: .success,
                                                title: t("settings__adv__addr_type_changed_title"),
                                                description: t(
                                                    "settings__adv__addr_type_changed_desc",
                                                    variables: ["type": addressType.localizedTitle]
                                                )
                                            )
                                        } else {
                                            app.toast(
                                                type: .error,
                                                title: t("settings__adv__addr_type_failed_title"),
                                                description: t("settings__adv__addr_type_change_failed_desc")
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if showDevSettings {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                CaptionMText(t("settings__adv__monitored_address_types"))
                                Spacer()
                                Button(action: { showMonitoredTypesNote.toggle() }) {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.textSecondary)
                                }
                            }
                            .padding(.top, 24)
                            .padding(.bottom, 8)

                            if showMonitoredTypesNote {
                                BodySText(
                                    t("settings__adv__addr_type_monitored_note"),
                                    textColor: .textSecondary
                                )
                                .padding(.bottom, 12)
                            }

                            VStack(spacing: 0) {
                                ForEach(AddressScriptType.allAddressTypes, id: \.self) { addressType in
                                    MonitoredAddressTypeToggle(
                                        addressType: addressType,
                                        isMonitored: settingsViewModel.isMonitoring(addressType),
                                        isSelectedType: settingsViewModel.selectedAddressType == addressType
                                    ) { enabled in
                                        loadingAddressType = addressType
                                        isMonitoringChange = true
                                        showLoadingView = true

                                        loadingTask = Task {
                                            var success = false
                                            let didTimeout = await withTimeout(seconds: timeoutSeconds) {
                                                success = await settingsViewModel.setMonitoring(addressType, enabled: enabled, wallet: wallet)
                                            }

                                            showLoadingView = false

                                            if didTimeout {
                                                app.toast(
                                                    type: .error,
                                                    title: t("settings__adv__addr_type_timeout_title"),
                                                    description: t("settings__adv__addr_type_timeout_desc")
                                                )
                                            } else if success {
                                                Haptics.notify(.success)
                                                app.toast(
                                                    type: .success,
                                                    title: t("settings__adv__addr_type_monitored_updated_title"),
                                                    description: t("settings__adv__addr_type_monitored_updated_desc")
                                                )
                                            } else if !enabled {
                                                if settingsViewModel.isLastRequiredNativeWitnessWallet(addressType) {
                                                    app.toast(
                                                        type: .error,
                                                        title: t("settings__adv__addr_type_cannot_disable_title"),
                                                        description: t("settings__adv__addr_type_cannot_disable_native_desc")
                                                    )
                                                } else {
                                                    app.toast(
                                                        type: .error,
                                                        title: t("settings__adv__addr_type_cannot_disable_title"),
                                                        description: t(
                                                            "settings__adv__addr_type_cannot_disable_balance_desc",
                                                            variables: ["type": addressType.localizedTitle]
                                                        )
                                                    )
                                                }
                                            } else {
                                                app.toast(
                                                    type: .error,
                                                    title: t("settings__adv__addr_type_failed_title"),
                                                    description: t("settings__adv__addr_type_monitored_failed_desc")
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Spacer()
                        .frame(height: 32)
                }
                .padding(.trailing, 4)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .fullScreenCover(isPresented: $showLoadingView) {
            AddressTypeLoadingView(
                targetAddressType: loadingAddressType,
                isMonitoringChange: isMonitoringChange
            )
        }
        .onDisappear {
            loadingTask?.cancel()
        }
    }
}

private struct TimeoutError: Error {}

/// Returns true if operation timed out.
private func withTimeout(seconds: UInt64, operation: @escaping () async -> some Any) async -> Bool {
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TimeoutError()
            }

            try await group.next()
            group.cancelAll()
        }
        return false
    } catch is TimeoutError {
        return true
    } catch {
        return false
    }
}

#Preview {
    let app = AppViewModel()
    return NavigationStack {
        AddressTypePreferenceView()
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(app)
            .environmentObject(WalletViewModel())
            .environmentObject(NavigationViewModel())
    }
    .preferredColorScheme(.dark)
}
