//
//  AppViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/10.
//

import BitkitCore
import LDKNode
import Network
import SwiftUI

@MainActor
class AppViewModel: ObservableObject {
    // Decoded from bitkit-core
    @Published var scannedLightningInvoice: LightningInvoice?
    // Should be removed once we have the string on the above struct: https://github.com/synonymdev/bitkit-core/issues/4
    @Published var scannedLightningBolt11Invoice: String?

    // Send flow
    @Published var scannedOnchainInvoice: OnChainInvoice?
    @Published var selectedWalletToPayFrom: WalletType = .onchain

    // LNURL Pay
    @Published var lnurlPayData: LnurlPayData?

    @Published var isGeoBlocked: Bool? = nil

    // Onboarding
    @AppStorage("hasSeenContactsIntro") var hasSeenContactsIntro: Bool = false
    @AppStorage("hasSeenProfileIntro") var hasSeenProfileIntro: Bool = false
    @AppStorage("hasSeenNotificationsIntro") var hasSeenNotificationsIntro: Bool = false
    @AppStorage("hasSeenQuickpayIntro") var hasSeenQuickpayIntro: Bool = false
    @AppStorage("hasSeenShopIntro") var hasSeenShopIntro: Bool = false
    @AppStorage("hasSeenTransferToSpendingIntro") var hasSeenTransferToSpendingIntro: Bool = false
    @AppStorage("hasSeenTransferToSavingsIntro") var hasSeenTransferToSavingsIntro: Bool = false
    @AppStorage("hasSeenWidgetsIntro") var hasSeenWidgetsIntro: Bool = false

    // When to show empty state UI
    @AppStorage("showHomeViewEmptyState") var showHomeViewEmptyState: Bool = false

    // App update tracking
    @AppStorage("appUpdateIgnoreTimestamp") var appUpdateIgnoreTimestamp: TimeInterval = 0

    // Backup warning tracking
    @AppStorage("backupVerified") var backupVerified: Bool = false
    @AppStorage("backupIgnoreTimestamp") var backupIgnoreTimestamp: TimeInterval = 0

    // High balance warning tracking
    @AppStorage("highBalanceIgnoreCount") var highBalanceIgnoreCount: Int = 0
    @AppStorage("highBalanceIgnoreTimestamp") var highBalanceIgnoreTimestamp: TimeInterval = 0

    // Drawer menu
    @Published var showDrawer = false

    // Network status
    enum NetworkStatus: String {
        case wifi = "wifi"
        case cellular = "cellular"
        case offline = "offline"
        case unknown = "unknown"
    }

    @Published var networkStatus: NetworkStatus = .unknown
    private let networkMonitor = NWPathMonitor()

    func showAllEmptyStates(_ show: Bool) {
        showHomeViewEmptyState = show
    }

    @Published var currentToast: Toast?

    private let lightningService: LightningService
    private let coreService: CoreService
    private let sheetViewModel: SheetViewModel
    private let navigationViewModel: NavigationViewModel

    init(
        lightningService: LightningService = .shared, coreService: CoreService = .shared, sheetViewModel: SheetViewModel,
        navigationViewModel: NavigationViewModel
    ) {
        self.lightningService = lightningService
        self.coreService = coreService
        self.sheetViewModel = sheetViewModel
        self.navigationViewModel = navigationViewModel

        // Start network monitoring
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            Logger.debug("Network path updated - Status: \(path.status), Interface Types: \(path.availableInterfaces.map { $0.type })")
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    if path.usesInterfaceType(.wifi) {
                        self.networkStatus = .wifi
                    } else if path.usesInterfaceType(.cellular) {
                        self.networkStatus = .cellular
                    } else {
                        self.networkStatus = .unknown
                    }
                } else {
                    self.networkStatus = .offline
                }
                Logger.debug("Current network status set to: \(self.networkStatus.rawValue)")
            }
        }
        networkMonitor.start(queue: DispatchQueue.main)

        Task {
            await checkGeoStatus()
            // Check for app updates on startup
            await AppUpdateService.shared.checkForAppUpdate()
        }
    }

    /// Handle deeplink URLs directly
    func handleURL(_ url: URL) async {
        Logger.info("Received deeplink: \(url.absoluteString)")

        do {
            try await handleScannedData(url.absoluteString)
            // Navigate to appropriate send view based on the invoice
            if invoiceRequiresCustomAmount == true {
                sheetViewModel.showSheet(.send, data: SendConfig(view: .amount))
            } else if invoiceRequiresCustomAmount == false {
                // Could add quickpay logic here too if needed
                sheetViewModel.showSheet(.send, data: SendConfig(view: .confirm))
            }
        } catch {
            toast(error)
        }
    }

    // Convenience initializer for previews and testing
    convenience init() {
        self.init(sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel())
    }

    deinit {
        networkMonitor.cancel()
    }

    func checkGeoStatus() async {
        do {
            isGeoBlocked = try await coreService.checkGeoStatus()
        } catch {
            Logger.error("Failed to check geo status: \(error)", context: "GeoCheck")
        }
    }

}

// MARK: Toast notifications

extension AppViewModel {
    func toast(type: Toast.ToastType, title: String, description: String? = nil, autoHide: Bool = true, visibilityTime: Double = 4.0) {
        switch type {
        case .error:
            Haptics.notify(.error)
        case .success:
            Haptics.notify(.success)
        case .info:
            Haptics.play(.heavy)
        case .lightning:
            Haptics.play(.rigid)
        case .warning:
            Haptics.notify(.warning)
        }

        let toast = Toast(type: type, title: title, description: description, autoHide: autoHide, visibilityTime: visibilityTime)
        ToastWindowManager.shared.showToast(toast)
    }

    func toast(_ error: Error) {
        toast(type: .error, title: "Error", description: error.localizedDescription)
    }

    func hideToast() {
        ToastWindowManager.shared.hideToast()
    }
}

// MARK: Scanning/pasting handling

extension AppViewModel {
    func handleScannedData(_ uri: String) async throws {
        // Reset send state before handling new data
        resetSendState()

        let data = try await decode(invoice: uri)

        switch data {
        // BIP21 (Unified) invoice handling
        case .onChain(let invoice):
            if let lnInvoice = invoice.params?["lightning"] {
                guard lightningService.status?.isRunning == true else {
                    toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                    return
                }
                // Lightning invoice param found, prefer lightning payment if possible
                if case .lightning(let lightningInvoice) = try await decode(invoice: lnInvoice) {
                    if lightningService.canSend(amountSats: lightningInvoice.amountSatoshis) {
                        handleScannedLightningInvoice(lightningInvoice, bolt11: lnInvoice, onchainInvoice: invoice)
                        return
                    }
                }
            }

            // No LN invoice found, proceed with onchain payment
            handleScannedOnchainInvoice(invoice)
        case .lightning(let invoice):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }

            Logger.debug("Lightning: \(invoice)")
            if lightningService.canSend(amountSats: invoice.amountSatoshis) {
                handleScannedLightningInvoice(invoice, bolt11: uri)
            } else {
                toast(type: .error, title: "Insufficient Funds", description: "You do not have enough funds to send this payment.")
            }
        case .lnurlPay(data: let lnurlPayData):
            Logger.debug("LNURL: \(lnurlPayData)")
            handleLnurlPayInvoice(lnurlPayData)
            break
        case .lnurlWithdraw(data: let lnurlWithdrawData):
            Logger.debug("LNURL: \(lnurlWithdrawData)")
            // TODO: Handle LNURL withdraw
            break
        case .lnurlChannel(data: let lnurlChannelData):
            Logger.debug("LNURL: \(lnurlChannelData)")
            // TODO: Handle LNURL channel
            break
        case .lnurlAuth(data: let lnurlAuthData):
            Logger.debug("LNURL: \(lnurlAuthData)")
            // TODO: Handle LNURL
            break
        case .nodeId(let url, let network):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }

            // TODO: add network check

            handleNodeId(url, network)
            break
        default:
            Logger.warn("Unhandled invoice type: \(data)")
            toast(type: .error, title: "Unsupported", description: "This type of invoice is not supported yet")
        }
    }

    private func handleScannedLightningInvoice(_ invoice: LightningInvoice, bolt11: String, onchainInvoice: OnChainInvoice? = nil) {
        scannedLightningInvoice = invoice
        scannedLightningBolt11Invoice = bolt11.trimmingCharacters(in: .whitespacesAndNewlines)
        scannedOnchainInvoice = onchainInvoice // Keep onchain invoice if provided
        selectedWalletToPayFrom = .lightning

        if invoice.amountSatoshis > 0 {
            Logger.debug("Found amount in invoice, proceeding with payment")
        } else {
            Logger.debug("No amount found in invoice, proceeding entering amount manually")
        }
    }

    private func handleScannedOnchainInvoice(_ invoice: OnChainInvoice) {
        scannedOnchainInvoice = invoice
        scannedLightningInvoice = nil
        selectedWalletToPayFrom = .onchain

        if invoice.amountSatoshis > 0 {
            Logger.debug("Found amount in invoice, proceeding with payment")
        } else {
            Logger.debug("No amount found in invoice, proceeding entering amount manually")
        }
    }

    private func handleLnurlPayInvoice(_ data: LnurlPayData) {
        // Check if lightning service is running
        guard lightningService.status?.isRunning == true else {
            toast(type: .error, title: "Lightning not running", description: "Please try again later.")
            return
        }

        // Check if user has enough lightning balance to pay the minimum amount
        let lightningBalance = lightningService.balances?.totalLightningBalanceSats ?? 0
        if lightningBalance < data.minSendable {
            toast(
                type: .warning,
                title: localizedString("other__lnurl_pay_error"),
                description: localizedString("other__lnurl_pay_error_no_capacity")
            )
            return
        }

        selectedWalletToPayFrom = .lightning
        lnurlPayData = data
    }

    private func handleNodeId(_ url: String, _ network: NetworkType) {
        sheetViewModel.hideSheet()
        navigationViewModel.navigate(.fundManual(nodeUri: url))
    }

    var invoiceRequiresCustomAmount: Bool? {
        if let invoice = scannedLightningInvoice {
            return invoice.amountSatoshis == 0
        } else if let invoice = scannedOnchainInvoice {
            return invoice.amountSatoshis == 0
        } else {
            return nil
        }
    }

    func resetSendState() {
        self.scannedLightningInvoice = nil
        self.scannedOnchainInvoice = nil
        self.selectedWalletToPayFrom = .onchain // Reset to default
        self.lnurlPayData = nil
        self.scannedLightningBolt11Invoice = nil
    }
}

// MARK: LDK Node Events

extension AppViewModel {
    func handleLdkNodeEvent(_ event: Event) {
        switch event {
        case .paymentReceived(let paymentId, let paymentHash, let amountMsat, let customRecords):
            sheetViewModel.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .lightning, sats: amountMsat / 1000))
            break
        case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            // Only relevant for channels to external nodes
            break
        case .channelReady(let channelId, userChannelId: _, counterpartyNodeId: _):
            // TODO: handle ONLY cjit as payment received. This makes it look like any channel confirmed is a received payment.
            if let channel = lightningService.channels?.first(where: { $0.channelId == channelId }) {
                sheetViewModel.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .lightning, sats: channel.inboundCapacityMsat / 1000))
            } else {
                toast(type: .error, title: "Channel opened", description: "Ready to send")
            }
            break
        case .channelClosed(channelId: _, userChannelId: _, counterpartyNodeId: _, reason: _):
            toast(type: .lightning, title: "Channel closed", description: "Balance moved from spending to savings")
            break
        case .paymentSuccessful(let paymentId, let paymentHash, let paymentPreimage, let feePaidMsat):
            // TODO: fee is not the sats sent. Need to get this amount from elsewhere like send flow or something.
            break
        case .paymentClaimable:
            break
        case .paymentFailed(paymentId: _, paymentHash: _, reason: _):
            break
        case .paymentForwarded(_, _, _, _, _, _, _, _, _, _):
            break
        }
    }
}

// MARK: - Timed Sheets

extension AppViewModel {
    func ignoreAppUpdate() {
        appUpdateIgnoreTimestamp = Date().timeIntervalSince1970
    }

    func ignoreBackup() {
        backupIgnoreTimestamp = Date().timeIntervalSince1970
    }

    func ignoreHighBalance() {
        highBalanceIgnoreCount += 1
        highBalanceIgnoreTimestamp = Date().timeIntervalSince1970
    }
}
