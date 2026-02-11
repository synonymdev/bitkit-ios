import LDKNode
import SwiftUI

extension AddressScriptType {
    var localizedTitle: String {
        switch self {
        case .legacy:
            return "Legacy"
        case .nestedSegwit:
            return "Nested Segwit"
        case .nativeSegwit:
            return "Native Segwit"
        case .taproot:
            return "Taproot"
        }
    }

    var localizedDescription: String {
        switch self {
        case .legacy:
            return "Pay-to-public-key-hash (1x...)"
        case .nestedSegwit:
            return "Pay-to-Script-Hash (3x...)"
        case .nativeSegwit:
            return "Pay-to-witness-public-key-hash (bc1x...)"
        case .taproot:
            return "Pay-to-Taproot (bc1px...)"
        }
    }

    var example: String {
        switch self {
        case .legacy:
            return "(1x...)"
        case .nestedSegwit:
            return "(3x...)"
        case .nativeSegwit:
            return "(bc1x...)"
        case .taproot:
            return "(bc1px...)"
        }
    }

    var shortExample: String {
        switch self {
        case .legacy:
            return "1x..."
        case .nestedSegwit:
            return "3x..."
        case .nativeSegwit:
            return "bc1q..."
        case .taproot:
            return "bc1p..."
        }
    }
}

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

extension AddressScriptType {
    var testId: String {
        switch self {
        case .legacy:
            return "p2pkh"
        case .nestedSegwit:
            return "p2sh-p2wpkh"
        case .nativeSegwit:
            return "p2wpkh"
        case .taproot:
            return "p2tr"
        }
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
                            BodySText("Currently selected", textColor: .textSecondary)
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
                            ForEach([AddressScriptType.legacy, .nestedSegwit, .nativeSegwit, .taproot], id: \.self) { addressType in
                                AddressTypeOption(
                                    addressType: addressType,
                                    isSelected: settingsViewModel.selectedAddressType == addressType
                                ) {
                                    guard settingsViewModel.selectedAddressType != addressType else { return }

                                    loadingAddressType = addressType
                                    isMonitoringChange = false
                                    showLoadingView = true

                                    loadingTask = Task {
                                        let didTimeout = await withTimeout(seconds: timeoutSeconds) {
                                            await settingsViewModel.updateAddressType(addressType, wallet: wallet)
                                        }

                                        showLoadingView = false

                                        if didTimeout {
                                            app.toast(type: .error, title: "Timeout", description: "The operation took too long. Please try again.")
                                        } else {
                                            Haptics.notify(.success)
                                            navigation.reset()
                                            app.toast(
                                                type: .success,
                                                title: "Address Type Changed",
                                                description: "Now using \(addressType.localizedTitle) addresses."
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
                                CaptionMText("Monitored Address Types")
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
                                    "Enable monitoring to track funds received at different address types. The app will watch these addresses for incoming transactions. Disabling monitoring for a type with balance may hide your funds.",
                                    textColor: .textSecondary
                                )
                                .padding(.bottom, 12)
                            }

                            VStack(spacing: 0) {
                                ForEach([AddressScriptType.legacy, .nestedSegwit, .nativeSegwit, .taproot], id: \.self) { addressType in
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
                                                    title: "Timeout",
                                                    description: "The operation took too long. Please try again."
                                                )
                                            } else if success {
                                                Haptics.notify(.success)
                                                app.toast(
                                                    type: .success,
                                                    title: "Settings Updated",
                                                    description: "Address monitoring settings applied."
                                                )
                                            } else if !enabled {
                                                // Determine reason for failure
                                                if settingsViewModel.isLastRequiredSegwitWallet(addressType) {
                                                    app.toast(
                                                        type: .error,
                                                        title: "Cannot Disable",
                                                        description: "At least one SegWit wallet is required for Lightning when using Legacy as primary."
                                                    )
                                                } else {
                                                    app.toast(
                                                        type: .error,
                                                        title: "Cannot Disable",
                                                        description: "\(addressType.localizedTitle) addresses have balance."
                                                    )
                                                }
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

/// Executes an async operation with a timeout. Returns true if the operation timed out.
private func withTimeout(seconds: UInt64, operation: @escaping () async -> some Any) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = await operation()
            return false // Operation completed
        }

        group.addTask {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            return true // Timeout
        }

        // Return whichever finishes first
        let result = await group.next() ?? false
        group.cancelAll()
        return result
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
