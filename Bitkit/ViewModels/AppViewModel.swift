//
//  AppViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/10.
//

import LDKNode
import SwiftUI

@MainActor
class AppViewModel: ObservableObject {
    // Decoded from bitkit-core
    @Published var scannedLightningInvoice: LightningInvoice?
    @Published var scannedLightningBolt11Invoice: String?  // Should be removed once we have the string on the above struct: https://github.com/synonymdev/bitkit-core/issues/4

    @Published var scannedOnchainInvoice: OnChainInvoice?
    @Published var sendAmountSats: UInt64?

    // Bottom sheets
    @Published var showReceiveSheet = false
    @Published var showSendOptionsSheet = false
    @Published var showScanner = false
    @Published var resetSendStateToggle = false
    @Published var showNewTransaction = false
    @Published var newTransaction: NewTransactionSheetDetails = .init(type: .lightning, direction: .received, sats: 0)
    @Published var showTransferToSpendingSheet = false
    @Published var showTransferToSavingsSheet = false

    // Bottom tab bar
    @Published var showTabBar = true
    @Published var isGeoBlocked: Bool? = nil

    @AppStorage("hasSeenTransferToSpendingIntro") var hasSeenTransferToSpendingIntro: Bool = false
    @AppStorage("hasSeenTransferToSavingsIntro") var hasSeenTransferToSavingsIntro: Bool = false

    // When to show empty state UI
    @AppStorage("showHomeViewEmptyState") var showHomeViewEmptyState: Bool = false
    @AppStorage("showSavingsViewEmptyState") var showSavingsViewEmptyState: Bool = false
    @AppStorage("showSpendingViewEmptyState") var showSpendingViewEmptyState: Bool = false

    func showAllEmptyStates(_ show: Bool) {
        showHomeViewEmptyState = show
        showSavingsViewEmptyState = show
        showSpendingViewEmptyState = show
    }

    @Published var currentToast: Toast?

    private let lightningService: LightningService
    private let coreService: CoreService

    init(lightningService: LightningService = .shared, coreService: CoreService = .shared) {
        self.lightningService = lightningService
        self.coreService = coreService

        Task {
            await checkGeoStatus()
        }
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
    func toast(type: Toast.ToastType, title: String, description: String? = nil, autoHide: Bool = true, visibilityTime: Double = 3.0) {
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

        withAnimation {
            currentToast = Toast(type: type, title: title, description: description, autoHide: autoHide, visibilityTime: visibilityTime)
        }

        if autoHide {
            DispatchQueue.main.asyncAfter(deadline: .now() + visibilityTime) {
                withAnimation {
                    self.currentToast = nil
                }
            }
        }
    }

    func toast(_ error: Error) {
        toast(type: .error, title: "Error", description: error.localizedDescription)
    }

    func hideToast() {
        withAnimation {
            currentToast = nil
        }
    }

    func showNewTransactionSheet(details: NewTransactionSheetDetails) {
        newTransaction = details

        // Hide these first if they're visible
        if showReceiveSheet || showSendOptionsSheet {
            showReceiveSheet = false
            showSendOptionsSheet = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self else { return }
                self.showNewTransaction = true
                Haptics.notify(.success)
            }
        } else {
            showNewTransaction = true
            Haptics.notify(.success)
        }
    }
}

// MARK: Scanning/pasting handling

extension AppViewModel {
    func handleScannedData(_ uri: String) async throws {
        let data = try await decode(invoice: uri)

        switch data {
        case let .onChain(invoice: invoice):
            guard lightningService.status?.isRunning == true else {
                toast(type: .error, title: "Lightning not running", description: "Please try again later.")
                return
            }
            if let lnInvoice = invoice.params?["lightning"] as? String {
                // Lightning invoice param found, prefer lightning payment if possible
                if case let .lightning(invoice: lightningInvoice) = try await decode(invoice: lnInvoice) {
                    if lightningService.canSend(amountSats: lightningInvoice.amountSatoshis) {
                        handleScannedLightningInvoice(lightningInvoice, bolt11: lnInvoice)
                        return
                    }
                }
            }

            // No LN invoice found, proceed with onchain payment
            handleScannedOnchainInvoice(invoice)
        case let .lightning(invoice: invoice):
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
        default:
            Logger.warn("Unhandled invoice type: \(data)")
            toast(type: .error, title: "Unsupported", description: "This type of invoice is not supported yet")
        }
    }

    private func handleScannedLightningInvoice(_ invoice: LightningInvoice, bolt11: String) {
        scannedLightningInvoice = invoice
        scannedLightningBolt11Invoice = bolt11.trimmingCharacters(in: .whitespacesAndNewlines)
        scannedOnchainInvoice = nil

        if invoice.amountSatoshis > 0 {
            Logger.info("Found amount in invoice, proceeding with payment")
        } else {
            Logger.info("No amount found in invoice, proceeding entering amount manually")
        }
    }

    private func handleScannedOnchainInvoice(_ invoice: OnChainInvoice) {
        scannedOnchainInvoice = invoice
        scannedLightningInvoice = nil

        if invoice.amountSatoshis > 0 {
            Logger.info("Found amount in invoice, proceeding with payment")
        } else {
            Logger.info("No amount found in invoice, proceeding entering amount manually")
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
        showSendOptionsSheet = false
        resetSendStateToggle.toggle()

        // After dropping the sheet reset displayed values
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.scannedLightningInvoice = nil
            self.scannedOnchainInvoice = nil
            self.sendAmountSats = nil
        }
    }
}

// MARK: LDK Node Events

extension AppViewModel {
    func handleLdkNodeEvent(_ event: Event) {
        switch event {
        case .paymentReceived(paymentId: _, paymentHash: _, let amountMsat):
            showNewTransactionSheet(details: .init(type: .lightning, direction: .received, sats: amountMsat / 1000))

        case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
            // Only relevant for channels to external nodes
            break

        case .channelReady(let channelId, userChannelId: _, counterpartyNodeId: _):
            // TODO: handle ONLY cjit as payment received. This makes it look like any channel confirmed is a received payment.
            if let channel = lightningService.channels?.first(where: { $0.channelId == channelId }) {
                showNewTransactionSheet(details: .init(type: .lightning, direction: .received, sats: channel.inboundCapacityMsat / 1000))
            } else {
                toast(type: .error, title: "Channel opened", description: "Ready to send")
            }

        case .channelClosed(channelId: _, userChannelId: _, counterpartyNodeId: _, reason: _):
            toast(type: .lightning, title: "Channel closed", description: "Balance moved from spending to savings")

        case .paymentSuccessful(paymentId: _, paymentHash: _, let feePaidMsat):
            showNewTransactionSheet(details: .init(type: .lightning, direction: .sent, sats: feePaidMsat ?? 0 / 1000))

        case .paymentClaimable:
            break

        case .paymentFailed(paymentId: _, paymentHash: _, reason: _):
            break
        }
    }
}
