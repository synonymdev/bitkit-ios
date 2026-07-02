import CoreBluetooth
import SwiftUI

struct HardwareIntroSheetItem: SheetItem {
    let id: SheetID = .hardwareIntro
    let size: SheetSize = .large
}

/// Entry point for the Connect Hardware flow, opened from the Home hardware suggestion card and the
/// Hardware Wallets settings Add button. Hosts the four connect steps (Intro → Searching → Found →
/// Paired) plus the inline Pair Device step shown when the device asks for its one-time pairing code.
/// Reads the shared `TrezorManager` from the environment and hands it to the flow driver.
struct HardwareIntroSheet: View {
    @Environment(TrezorManager.self) private var trezorManager
    let config: HardwareIntroSheetItem

    var body: some View {
        HardwareConnectFlow(
            service: TrezorHwConnectService(trezorManager: trezorManager),
            config: config
        )
    }
}

/// Drives the phase-based Connect Hardware wizard. Cancel/back always dismisses the sheet (never
/// steps backward), so each phase is rendered from a single `phase` switch rather than a back stack.
private struct HardwareConnectFlow: View {
    @Environment(TrezorManager.self) private var trezorManager
    @Environment(HwWalletManager.self) private var hwWalletManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var navigation: NavigationViewModel

    let config: HardwareIntroSheetItem

    @State private var viewModel: HwConnectViewModel
    @State private var showBluetoothAlert = false

    init(service: HwConnectServicing, config: HardwareIntroSheetItem) {
        self.config = config
        _viewModel = State(initialValue: HwConnectViewModel(service: service))
    }

    var body: some View {
        Sheet(id: .hardwareIntro, data: config) {
            Group {
                switch viewModel.phase {
                case .intro:
                    introStep
                case .searching:
                    HwSearchingView(errorMessage: viewModel.errorMessage, onCancel: { sheets.hideSheet() })
                case .found:
                    HwFoundView(
                        deviceModel: foundDeviceModel,
                        isConnecting: viewModel.isConnecting,
                        errorMessage: viewModel.errorMessage,
                        onConnect: viewModel.onConnect,
                        onCancel: {
                            viewModel.cancelConnect()
                            sheets.hideSheet()
                        }
                    )
                case .paired:
                    HwPairedView(
                        deviceName: viewModel.deviceName,
                        balanceSats: viewModel.balanceSats,
                        labelText: labelBinding,
                        onFinish: viewModel.onFinish
                    )
                case .pairCode:
                    HwPairCodeView(onSubmit: { trezorManager.submitPairingCode($0) })
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
        }
        .onChange(of: trezorManager.showPairingCode) { _, needsCode in
            if needsCode { viewModel.onPairingCodeRequested() }
        }
        .onChange(of: connectedWalletKey) { _, _ in
            viewModel.onWalletsUpdated(hwWalletManager.wallets)
        }
        .task {
            viewModel.onFinished = {
                sheets.hideSheet()
                navigation.reset()
            }
        }
        .onDisappear { viewModel.reset() }
        .alert(bluetoothAlertTitle, isPresented: $showBluetoothAlert) {
            Button(t("common__cancel"), role: .cancel) {}
            Button(t("hardware__bluetooth_open_settings")) { openSettings() }
        } message: {
            Text(bluetoothAlertMessage)
        }
    }

    // MARK: - Intro step

    private var introStep: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__intro_title"))
                .padding(.horizontal, 16)

            HwDeviceIllustrations()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("hardware__intro_header"), accentColor: .blueAccent)

                BodyMText(t("hardware__intro_text"))
                    .padding(.top, 8)

                HStack(spacing: 16) {
                    CustomButton(title: t("common__cancel"), variant: .secondary, shouldExpand: true) {
                        sheets.hideSheet()
                    }
                    .accessibilityIdentifier("HwIntroCancel")

                    CustomButton(title: t("common__continue"), shouldExpand: true) {
                        onContinueTapped()
                    }
                    .accessibilityIdentifier("HwIntroContinue")
                }
                .padding(.top, 32)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 32)
        }
        .accessibilityIdentifier("HwIntroSheet")
    }

    private func onContinueTapped() {
        if isBluetoothUsable {
            viewModel.onIntroContinue()
        } else {
            showBluetoothAlert = true
        }
    }

    // MARK: - Helpers

    private var foundDeviceModel: String {
        viewModel.foundDeviceModel.isEmpty ? t("hardware__device_model_trezor") : viewModel.foundDeviceModel
    }

    private var labelBinding: Binding<String> {
        Binding(get: { viewModel.labelInput }, set: { viewModel.onLabelChange($0) })
    }

    /// Changes whenever the paired wallet's name or balance changes, so the balance shown on the
    /// Paired step tracks incoming watcher updates.
    private var connectedWalletKey: String {
        guard let deviceId = viewModel.pairedDeviceId else { return "" }
        guard let wallet = hwWalletManager.wallets.first(where: { $0.id == deviceId || $0.deviceIds.contains(deviceId) })
        else { return "" }
        return "\(wallet.name)\u{1}\(wallet.balanceSats)"
    }

    private var isBluetoothUsable: Bool {
        switch trezorManager.bluetoothState {
        case .poweredOn, .unknown, .resetting:
            return true
        default:
            return false
        }
    }

    private var bluetoothAlertTitle: String {
        switch trezorManager.bluetoothState {
        case .poweredOff: return t("hardware__bluetooth_off_title")
        case .unauthorized: return t("hardware__bluetooth_unauthorized_title")
        case .unsupported: return t("hardware__bluetooth_unsupported_title")
        default: return t("hardware__bluetooth_unavailable_title")
        }
    }

    private var bluetoothAlertMessage: String {
        switch trezorManager.bluetoothState {
        case .poweredOff: return t("hardware__bluetooth_off_text")
        case .unauthorized: return t("hardware__bluetooth_unauthorized_text")
        case .unsupported: return t("hardware__bluetooth_unsupported_text")
        default: return t("hardware__bluetooth_unavailable_text")
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
