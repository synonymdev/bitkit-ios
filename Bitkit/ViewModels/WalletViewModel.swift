//
//  WalletViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import BitkitCore
import LDKNode
import SwiftUI

@MainActor
class WalletViewModel: ObservableObject {
    @Published var walletExists: Bool? = nil
    @Published var isSyncingWallet = false // Syncing both LN and on chain
    @AppStorage("totalBalanceSats") var totalBalanceSats: Int = 0 // Combined onchain and LN
    @AppStorage("totalOnchainSats") var totalOnchainSats: Int = 0 // Combined onchain
    @AppStorage("totalLightningSats") var totalLightningSats: Int = 0 // Combined LN
    @AppStorage("defaultTransactionSpeed") var defaultTransactionSpeed: TransactionSpeed = .medium

    // Receiving
    @AppStorage("onchainAddress") var onchainAddress = ""
    @AppStorage("bolt11") var bolt11 = ""
    @AppStorage("bip21") var bip21 = ""
    @AppStorage("channelCount") var channelCount: Int = 0 // Keeping a cached version of this so we can better aniticipate the receive flow UI

    // For bolt11 details and bip21 params
    var invoiceAmountSats: UInt64 = 0
    var invoiceNote: String = ""

    @Published var nodeLifecycleState: NodeLifecycleState = .stopped
    @Published var nodeStatus: NodeStatus?
    @Published var nodeId: String?
    @Published var balanceDetails: BalanceDetails?
    @Published var peers: [PeerDetails]?
    @Published var channels: [ChannelDetails]?
    private var eventHandlers: [String: (Event) -> Void] = [:]
    private var syncTimer: Timer?

    private let lightningService: LightningService
    private let coreService: CoreService

    @Published var isRestoringWallet = false

    init(lightningService: LightningService = .shared, coreService: CoreService = .shared) {
        self.lightningService = lightningService
        self.coreService = coreService
    }

    deinit {
        Task { [weak self] in
            await self?.stopPolling()
        }
    }

    func setWalletExistsState() throws {
        walletExists = try Keychain.exists(key: .bip39Mnemonic(index: 0))
    }

    func addOnEvent(id: String, handler: @escaping (Event) -> Void) {
        eventHandlers[id] = handler
    }

    func removeOnEvent(id: String) {
        eventHandlers.removeValue(forKey: id)
    }

    func start(walletIndex: Int = 0) async throws {
        if nodeLifecycleState != .initializing {
            // Initilaizing means it's a wallet restore or create so we need to show the loading view
            nodeLifecycleState = .starting
        }

        syncState()
        do {
            try await lightningService.setup(walletIndex: walletIndex)
            try await lightningService.start(onEvent: { event in
                // On every lightning event just sync UI
                Task { @MainActor in
                    self.syncState()
                    // Notify all event handlers
                    for handler in self.eventHandlers.values {
                        handler(event)
                    }

                    // If payment received or new channel events, refresh BIP21 for instantly usable QR in receive view
                    switch event {
                    case .paymentReceived, .channelReady, .channelClosed:
                        self.bolt11 = ""
                        Task {
                            try? await self.refreshBip21()
                        }
                    default:
                        break
                    }
                }
            })
        } catch {
            nodeLifecycleState = .errorStarting(cause: error)
            throw error
        }

        nodeLifecycleState = .running

        startPolling()

        syncState()

        do {
            try await lightningService.connectToTrustedPeers()
        } catch {
            Logger.error("Failed to connect to trusted peers")
        }

        Task { @MainActor in
            try await refreshBip21()
        }

        // Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }

    func stopLightningNode() async throws {
        nodeLifecycleState = .stopping
        stopPolling()
        try await lightningService.stop()
        nodeLifecycleState = .stopped
        syncState()
    }

    func wipeLightningWallet() async throws {
        if nodeLifecycleState == .starting || nodeLifecycleState == .running {
            try await stopLightningNode()
        }

        try await lightningService.wipeStorage(walletIndex: 0)

        // Reset AppStorage display values
        totalBalanceSats = 0
        totalOnchainSats = 0
        totalLightningSats = 0

        onchainAddress = ""
        bolt11 = ""
        bip21 = ""
    }

    func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        let finalExpirySecs = expirySecs ?? 60 * 60 * 24
        return try await lightningService.receive(amountSats: amountSats, description: note, expirySecs: finalExpirySecs)
    }

    func waitForNodeToRun(timeoutSeconds: Double = 10.0) async -> Bool {
        guard nodeLifecycleState != .running else { return true }

        if nodeLifecycleState != .starting {
            return false
        }

        let startTime = Date()

        while nodeLifecycleState == .starting {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay

            // Check for timeout
            if Date().timeIntervalSince(startTime) > timeoutSeconds {
                return false
            }

            // Break if task cancelled
            if Task.isCancelled {
                break
            }
        }

        return nodeLifecycleState == .running
    }

    func sync() async throws {
        syncState()

        if isSyncingWallet {
            Logger.warn("Sync already in progress, waiting for existing sync.")
            while isSyncingWallet {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return
        }

        isSyncingWallet = true
        syncState()

        do {
            try await lightningService.sync()
        } catch {
            isSyncingWallet = false
            throw error
        }

        isSyncingWallet = false
        syncState()
    }

    /// Sends bitcoin to an on-chain address
    /// - Parameters:
    ///   - address: The bitcoin address to send to
    ///   - sats: The amount in satoshis to send
    ///   - speed: The transaction speed determining the fee rate. If nil, the user's default transaction speed will be used.
    /// - Returns: The transaction ID (txid) of the sent transaction
    /// - Throws: An error if the transaction fails or if fee rates cannot be retrieved
    func send(address: String, sats: UInt64, speed: TransactionSpeed? = nil) async throws -> Txid {
        var fees = try? await coreService.blocktank.fees(refresh: true)
        if fees == nil {
            Logger.warn("Failed to fetch fresh fee rate, using cached rate.")
            fees = try await coreService.blocktank.fees(refresh: false)
        }

        guard let fees else {
            throw AppError(message: "Fees unavailable from bitkit-core", debugMessage: nil)
        }

        let satsPerVbyte = fees.getSatsPerVbyte(for: speed ?? defaultTransactionSpeed)

        let txid = try await lightningService.send(address: address, sats: sats, satsPerVbyte: satsPerVbyte)
        Task {
            // Best to auto sync on chain so we have latest state
            try await sync()
        }
        return txid
    }

    func send(bolt11: String, sats: UInt64? = nil, onSuccess: @escaping () -> Void, onFail: @escaping (String) -> Void) async throws -> PaymentHash {
        let hash = try await lightningService.send(bolt11: bolt11, sats: sats)
        let eventId = String(hash)

        // Add event listener for this specific payment
        addOnEvent(id: eventId) { event in
            switch event {
            case .paymentSuccessful(let paymentId, let paymentHash, _, _):
                if paymentHash == hash {
                    self.removeOnEvent(id: eventId)
                    onSuccess()
                }
            case .paymentFailed(paymentId: _, let paymentHash, let reason):
                if paymentHash == hash {
                    self.removeOnEvent(id: eventId)
                    onFail(reason.debugDescription)
                }
            default:
                break
            }
        }

        syncState()
        return hash
    }

    func closeChannel(_ channel: ChannelDetails) async throws {
        try await lightningService.closeChannel(userChannelId: channel.userChannelId, counterpartyNodeId: channel.counterpartyNodeId)
        syncState()
    }

    func syncState() {
        nodeStatus = lightningService.status
        nodeId = lightningService.nodeId
        balanceDetails = lightningService.balances
        peers = lightningService.peers
        channels = lightningService.channels

        if let channels {
            channelCount = channels.count
        }

        if let balanceDetails {
            totalOnchainSats = Int(balanceDetails.totalOnchainBalanceSats)
            totalLightningSats = Int(balanceDetails.totalLightningBalanceSats)
            totalBalanceSats = Int(balanceDetails.totalLightningBalanceSats + balanceDetails.totalOnchainBalanceSats)
        }
    }

    var incomingLightningCapacitySats: UInt64? {
        guard let channels else {
            return nil
        }

        var capacity: UInt64 = 0
        for channel in channels {
            capacity += channel.inboundCapacityMsat / 1000
        }
        return capacity
    }

    func refreshBip21(forceRefreshBolt11: Bool = false) async throws {
        if onchainAddress.isEmpty {
            onchainAddress = try await lightningService.newAddress()
        } else {
            // Check if current address has been used
            let addressInfo = try await AddressChecker.getAddressInfo(address: onchainAddress)
            let hasTransactions = addressInfo.chain_stats.tx_count > 0 || addressInfo.mempool_stats.tx_count > 0

            if hasTransactions {
                // Address has been used, generate a new one
                onchainAddress = try await lightningService.newAddress()
            }
        }

        var newBip21 = "bitcoin:\(onchainAddress)"

        let amountSats = invoiceAmountSats > 0 ? invoiceAmountSats : nil
        let note = invoiceNote.isEmpty ? "Bitkit" : invoiceNote

        if channels?.count ?? 0 > 0 {
            if forceRefreshBolt11 || bolt11.isEmpty {
                bolt11 = try await self.createInvoice(amountSats: amountSats, note: note)
            } else {
                //Existing invoice needs to be checked for expiry
                if case .lightning(let lightningInvoice) = try await decode(invoice: bolt11) {
                    if lightningInvoice.isExpired {
                        bolt11 = try await self.createInvoice(amountSats: amountSats, note: note)
                    }
                }
            }
        } else {
            bolt11 = ""
        }

        if !bolt11.isEmpty {
            newBip21 += "?lightning=\(bolt11)"
        }

        // Add amount and note if available
        if invoiceAmountSats > 0 {
            let separator = newBip21.contains("?") ? "&" : "?"
            newBip21 += "\(separator)amount=\(Double(invoiceAmountSats) / 100_000_000.0)"
        }

        if !invoiceNote.isEmpty {
            let separator = newBip21.contains("?") ? "&" : "?"
            if let encodedNote = invoiceNote.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                newBip21 += "\(separator)message=\(encodedNote)"
            }
        }

        bip21 = newBip21
    }

    private func startPolling() {
        stopPolling()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.nodeLifecycleState == .running {
                    self.syncState()
                }
            }
        }
    }

    private func stopPolling() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
