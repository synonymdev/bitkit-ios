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

    @Published var scannedOnchainInvoice: OnChainInvoice?
    @Published var sendAmountSats: UInt64?
    @Published var selectedWalletToPayFrom: WalletType = .onchain

    @Published var isGeoBlocked: Bool? = nil

    // Onboarding
    @AppStorage("hasSeenContactsIntro") var hasSeenContactsIntro: Bool = false
    @AppStorage("hasSeenProfileIntro") var hasSeenProfileIntro: Bool = false
    @AppStorage("hasSeenQuickpayIntro") var hasSeenQuickpayIntro: Bool = false
    @AppStorage("hasSeenShopIntro") var hasSeenShopIntro: Bool = false
    @AppStorage("hasSeenTransferToSpendingIntro") var hasSeenTransferToSpendingIntro: Bool = false
    @AppStorage("hasSeenTransferToSavingsIntro") var hasSeenTransferToSavingsIntro: Bool = false
    @AppStorage("hasSeenWidgetsIntro") var hasSeenWidgetsIntro: Bool = false

    // When to show empty state UI
    @AppStorage("showHomeViewEmptyState") var showHomeViewEmptyState: Bool = false

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

    init(lightningService: LightningService = .shared, coreService: CoreService = .shared, sheetViewModel: SheetViewModel) {
        self.lightningService = lightningService
        self.coreService = coreService
        self.sheetViewModel = sheetViewModel

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
        }
    }

    // Convenience initializer for previews and testing
    convenience init() {
        self.init(sheetViewModel: SheetViewModel())
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
        let data = try await decode(invoice: uri)

        switch data {
        case .onChain(let invoice):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }
            if let lnInvoice = invoice.params?["lightning"] as? String {
                // Lightning invoice param found, prefer lightning payment if possible
                if case .lightning(let lightningInvoice) = try await decode(invoice: lnInvoice) {
                    if lightningService.canSend(amountSats: lightningInvoice.amountSatoshis) {
                        selectedWalletToPayFrom = .lightning
                        handleScannedLightningInvoice(lightningInvoice, bolt11: lnInvoice, onchainInvoice: invoice)
                        return
                    }
                }
            }

            // No LN invoice found, proceed with onchain payment
            selectedWalletToPayFrom = .onchain
            handleScannedOnchainInvoice(invoice)
        case .lightning(let invoice):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }

            Logger.debug("Lightning: \(invoice)")
            if lightningService.canSend(amountSats: invoice.amountSatoshis) {
                selectedWalletToPayFrom = .lightning
                handleScannedLightningInvoice(invoice, bolt11: uri)
            } else {
                toast(type: .error, title: "Insufficient Funds", description: "You do not have enough funds to send this payment.")
            }
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
        sheetViewModel.hideSheet()

        // After dropping the sheet reset displayed values
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.scannedLightningInvoice = nil
            self.scannedOnchainInvoice = nil
            self.sendAmountSats = nil
            self.selectedWalletToPayFrom = .onchain // Reset to default
        }
    }
}

// MARK: LDK Node Events

extension AppViewModel {
    func handleLdkNodeEvent(_ event: Event) {
        switch event {
        case .paymentReceived(let paymentId, let paymentHash, let amountMsat, let customRecords):
            sheetViewModel.showSheet(.receivedTx, data: NewTransactionSheetDetails(type: .lightning, direction: .received, sats: amountMsat / 1000))
            break
        case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            // Only relevant for channels to external nodes
            break
        case .channelReady(let channelId, userChannelId: _, counterpartyNodeId: _):
            // TODO: handle ONLY cjit as payment received. This makes it look like any channel confirmed is a received payment.
            if let channel = lightningService.channels?.first(where: { $0.channelId == channelId }) {
                sheetViewModel.showSheet(
                    .receivedTx, data: NewTransactionSheetDetails(type: .lightning, direction: .received, sats: channel.inboundCapacityMsat / 1000))
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
