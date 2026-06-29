import BitkitCore
import SwiftUI

/// Detail overview of a paired hardware wallet, tracked as a watch-only balance. Mirrors the
/// Savings/Spending screens: device name + blue Bitcoin icon in the top bar, balance header, the
/// device's on-chain activity grouped by date (blue hardware icons), a Transfer-To-Spending
/// placeholder on funded devices, and a Remove action. Ports bitkit-android's `HardwareWalletScreen`.
struct HardwareWalletScreen: View {
    let deviceId: String

    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(TrezorManager.self) private var trezorManager

    @State private var activities: [Activity] = []
    @State private var showRemoveDialog = false

    private var wallet: HwWallet? {
        hwWalletManager.wallets.first { $0.deviceIds.contains(deviceId) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let wallet {
                NavigationBar(title: wallet.name, icon: "btc-circle-blue")
                    .padding(.horizontal, 16)

                content(for: wallet)

                bottomGradient
            }
        }
        .navigationBarHidden(true)
        .task(id: wallet?.walletId) {
            await loadActivities()
        }
        .onReceive(activity.activitiesChangedPublisher) { _ in
            Task { await loadActivities() }
        }
        // Leave the screen once the device is gone, whether removed here or forgotten elsewhere.
        .onChange(of: hwWalletManager.wallets.contains { $0.deviceIds.contains(deviceId) }) { _, stillPaired in
            if hwWalletManager.walletsLoaded, !stillPaired {
                navigation.navigateBack()
            }
        }
        .alert(
            t("hardware__remove_dialog_title", variables: ["name": wallet?.name ?? ""]),
            isPresented: $showRemoveDialog
        ) {
            Button(t("common__remove"), role: .destructive) {
                Task { await removeWallet() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("hardware__remove_dialog_text"))
        }
    }

    private func content(for wallet: HwWallet) -> some View {
        let hasFunds = wallet.balanceSats > 0
        let hasActivity = !activities.isEmpty

        return VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                MoneyStack(
                    sats: Int(clamping: wallet.balanceSats),
                    showSymbol: true,
                    enableSwipeGesture: true,
                    enableHide: true,
                    testIdPrefix: "TotalBalance"
                )

                if hasFunds {
                    transferButton
                        .padding(.top, 28)
                }

                if hasActivity {
                    HardwareWalletActivityList(activities: activities)
                        .padding(.top, 32)
                }

                removeButton(for: wallet)
                    .padding(.top, 16)
            }
            .contentMargins(.top, ScreenLayout.topPaddingWithoutSafeArea)
            .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .padding(.horizontal)
        .background(alignment: .topTrailing) {
            Image("trezor-wallet-overview")
                .resizable()
                .frame(width: 256, height: 256)
                .offset(x: 118)
        }
    }

    private var transferButton: some View {
        CustomButton(
            title: t("lightning__transfer_to_spending_button"),
            variant: .secondary,
            icon: Image("arrow-up-down")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundColor(.white80)
        ) {
            app.toast(type: .warning, title: t("hardware__transfer_not_implemented"))
        }
        .accessibilityIdentifier("HwTransferToSpending")
    }

    private func removeButton(for wallet: HwWallet) -> some View {
        CustomButton(
            title: t("hardware__remove_button", variables: ["name": wallet.name]),
            variant: .tertiary
        ) {
            showRemoveDialog = true
        }
        .accessibilityIdentifier("RemoveHardwareWallet")
    }

    private var bottomGradient: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [.black.opacity(0), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: ScreenLayout.bottomPaddingWithSafeArea)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    private func loadActivities() async {
        guard let walletId = wallet?.walletId else { return }
        do {
            activities = try await CoreService.shared.activity.get(filter: .all, walletId: walletId)
        } catch {
            Logger.error(error, context: "HardwareWalletScreen failed to load activities")
        }
    }

    /// Stop watching and forget every entry for this wallet (the same device may be paired over
    /// multiple transports). `removeDevice` stops the watchers and deletes the persisted activities;
    /// `forgetDevice` clears credentials and drops the known-device entry, which re-pushes the device
    /// snapshot and removes the tile. The reactive auto-pop above then leaves the screen.
    private func removeWallet() async {
        guard let wallet else { return }
        hwWalletManager.removeDevice(id: wallet.id)
        for id in wallet.deviceIds {
            await trezorManager.forgetDevice(id: id)
        }
    }
}

/// The hardware wallet's on-chain activity, grouped by date and rendered with the shared activity
/// row. Hardware activities draw the blue icon automatically (derived from their `walletId`).
private struct HardwareWalletActivityList: View {
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager

    let activities: [Activity]

    var body: some View {
        let groupedItems = activity.groupActivities(activities)

        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(zip(groupedItems.indices, groupedItems)), id: \.1) { index, groupItem in
                switch groupItem {
                case let .header(title):
                    CaptionMText(title)
                        .frame(height: 34, alignment: .bottom)

                case let .activity(item):
                    NavigationLink(value: Route.activityDetail(item)) {
                        ActivityRow(item: item, feeEstimates: feeEstimatesManager.estimates)
                    }
                    .accessibilityIdentifier("Activity-\(index)")
                }
            }
        }
    }
}
