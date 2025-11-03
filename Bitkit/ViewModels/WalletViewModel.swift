import BitkitCore
import LDKNode
import SwiftUI

@MainActor
class WalletViewModel: ObservableObject {
    @Published var walletExists: Bool? = nil
    @Published var isSyncingWallet = false // Syncing both LN and on chain
    @AppStorage("totalBalanceSats") var totalBalanceSats: Int = 0 // Combined onchain and LN
    @AppStorage("totalOnchainSats") var totalOnchainSats: Int = 0 // The total balance of our on-chain wallet
    @AppStorage("totalLightningSats") var totalLightningSats: Int = 0 // Combined LN
    @AppStorage("spendableOnchainBalanceSats") var spendableOnchainBalanceSats: Int = 0 // The spendable balance of our on-chain wallet
    @AppStorage("maxSendLightningSats") var maxSendLightningSats: Int = 0 // Maximum amount that can be sent via lightning (outbound capacity)

    // Receive flow
    @AppStorage("onchainAddress") var onchainAddress = ""
    @AppStorage("bolt11") var bolt11 = ""
    @AppStorage("bip21") var bip21 = ""
    @AppStorage("channelCount") var channelCount: Int = 0 // Keeping a cached version of this so we can better aniticipate the receive flow UI

    // Send flow
    @Published var sendAmountSats: UInt64?
    @Published var selectedFeeRateSatsPerVByte: UInt32?
    @Published var selectedSpeed: TransactionSpeed = .normal
    @Published var selectedUtxos: [SpendableUtxo]?
    @Published var availableUtxos: [SpendableUtxo] = []
    @Published var isMaxAmountSend: Bool = false

    // LNURL withdraw flow
    @Published var lnurlWithdrawAmount: UInt64?

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
    private let electrumConfigService: ElectrumConfigService
    private let rgsConfigService: RgsConfigService
    private let balanceManager: BalanceManager
    private let transferService: TransferService

    @Published var isRestoringWallet = false
    @Published var balanceInTransferToSavings: Int = 0
    @Published var balanceInTransferToSpending: Int = 0

    init(
        lightningService: LightningService = .shared,
        coreService: CoreService = .shared,
        electrumConfigService: ElectrumConfigService = ElectrumConfigService(),
        rgsConfigService: RgsConfigService = RgsConfigService(),
        transferService: TransferService? = nil
    ) {
        self.lightningService = lightningService
        self.coreService = coreService
        self.electrumConfigService = electrumConfigService
        self.rgsConfigService = rgsConfigService
        self.transferService = transferService ?? TransferService(
            lightningService: lightningService,
            blocktankService: coreService.blocktank
        )
        balanceManager = BalanceManager(
            lightningService: lightningService,
            transferService: self.transferService,
            coreService: coreService
        )
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
            let electrumServerUrl = electrumConfigService.getCurrentServer().url
            let rgsServerUrl = rgsConfigService.getCurrentServerUrl()
            try await lightningService.setup(
                walletIndex: walletIndex,
                electrumServerUrl: electrumServerUrl,
                rgsServerUrl: rgsServerUrl.isEmpty ? nil : rgsServerUrl
            )
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

    func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        let finalExpirySecs = expirySecs ?? 60 * 60 * 24
        let invoice = try await lightningService.receive(amountSats: amountSats, description: note, expirySecs: finalExpirySecs)
        return invoice.lowercased()
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
    ///   - isMaxAmount: Whether this is a max amount send (uses sendAllToAddress)
    /// - Returns: The transaction ID (txid) of the sent transaction
    /// - Throws: An error if the transaction fails or if fee rates cannot be retrieved
    func send(address: String, sats: UInt64, isMaxAmount: Bool = false) async throws -> Txid {
        guard let selectedFeeRateSatsPerVByte else {
            throw AppError(message: "Fee rate not set", debugMessage: "Please set a fee rate before selecting UTXOs.")
        }

        if let selectedUtxos {
            Logger.info("Using selected UTXO for send: \(selectedUtxos)")
        } else {
            Logger.warn("No UTXO selected, using default selection algorithm.")
        }

        let txid = try await lightningService.send(
            address: address,
            sats: sats,
            satsPerVbyte: selectedFeeRateSatsPerVByte,
            utxosToSpend: selectedUtxos,
            isMaxAmount: isMaxAmount
        )

        Task {
            // Best to auto sync on chain so we have latest state
            try await sync()
        }

        return txid
    }

    /// Sets the fee rate for the send flow
    /// - Parameter speed: The transaction speed determining the fee rate. If nil, the user's default transaction speed will be used.
    func setFeeRate(speed: TransactionSpeed) async throws {
        var fees = try? await coreService.blocktank.fees(refresh: true)
        if fees == nil {
            Logger.warn("Failed to fetch fresh fee rate, using cached rate.")
            fees = try await coreService.blocktank.fees(refresh: false)
        }

        guard let fees else {
            throw AppError(message: "Fees unavailable from bitkit-core", debugMessage: nil)
        }

        selectedFeeRateSatsPerVByte = speed.getFeeRate(from: fees)

        Logger.info("Selected fee rate: \(selectedFeeRateSatsPerVByte ?? 0) sats/vbyte for speed: \(speed)")
    }

    func loadAvailableUtxos() async throws {
        availableUtxos = try await lightningService.listSpendableOutputs()
    }

    /// Sets the UTXO selection for the send flow using the specified coin selection algorithm.based on chosen fee and target amount
    func setUtxoSelection(coinSelectionAlgorythm: CoinSelectionAlgorithm) async throws {
        guard let selectedFeeRateSatsPerVByte else {
            throw AppError(message: "Fee rate not set", debugMessage: "Please set a fee rate before selecting UTXOs.")
        }

        guard let sendAmountSats else {
            throw AppError(message: "Send amount not set", debugMessage: "Please set a send amount before selecting UTXOs.")
        }

        Logger.info(
            "Selecting UTXOs with algorithm: \(coinSelectionAlgorythm), target amount: \(sendAmountSats) sats, fee rate: \(selectedFeeRateSatsPerVByte) sats/vbyte"
        )

        selectedUtxos = try await lightningService.selectUtxosWithAlgorithm(
            targetAmountSats: sendAmountSats,
            satsPerVbyte: selectedFeeRateSatsPerVByte,
            coinSelectionAlgorythm: coinSelectionAlgorythm,
            utxos: nil
        )

        Logger.info("Selected UTXOs: \(String(describing: selectedUtxos))")
    }

    /// Gets fee limits for custom fee input
    /// - Returns: Tuple with (minFee, maxFee) in sat/vB
    func getFeeLimits() async -> (minFee: UInt32, maxFee: UInt32) {
        do {
            guard let fees = try await coreService.blocktank.fees(refresh: false) else {
                return (minFee: 1, maxFee: 999)
            }

            let slowRate = TransactionSpeed.slow.getFeeRate(from: fees)
            let fastRate = TransactionSpeed.fast.getFeeRate(from: fees)

            // Set minimum to slow rate, maximum to 3x fast rate (capped at 999)
            let minFee = slowRate
            // TODO: check what the max fee rate should be
            let maxFee = min(fastRate * 3, 999)

            return (minFee: minFee, maxFee: maxFee)
        } catch {
            Logger.error("Failed to get fee limits: \(error)")
            return (minFee: 1, maxFee: 999)
        }
    }

    /// Gets the current fee estimates for display
    /// - Returns: FeeRates object with current network rates, or nil if unavailable
    func getCurrentFeeEstimates() async -> FeeRates? {
        do {
            return try await coreService.blocktank.fees(refresh: false)
        } catch {
            Logger.error("Failed to get fee estimates: \(error)")
            return nil
        }
    }

    /// Calculates the fee for a transaction
    /// - Parameters:
    ///   - address: The destination address
    ///   - amountSats: The amount to send in satoshis
    ///   - satsPerVByte: The fee rate in satoshis per virtual byte
    ///   - utxosToSpend: Optional specific UTXOs to spend
    /// - Returns: The actual fee in satoshis
    /// - Throws: Error if calculation fails
    func calculateTotalFee(
        address: String,
        amountSats: UInt64,
        satsPerVByte: UInt32,
        utxosToSpend: [SpendableUtxo]? = nil
    ) async throws -> UInt64 {
        return try await lightningService.calculateTotalFee(
            address: address,
            amountSats: amountSats,
            satsPerVByte: satsPerVByte,
            utxosToSpend: utxosToSpend
        )
    }

    /// Calculates the maximum sendable amount for onchain transactions
    /// - Parameters:
    ///   - address: The destination address
    ///   - satsPerVByte: The fee rate in satoshis per virtual byte
    /// - Returns: The maximum amount that can be sent (balance minus fees)
    /// - Throws: Error if calculation fails
    func calculateMaxSendableAmount(
        address: String,
        satsPerVByte: UInt32
    ) async throws -> UInt64 {
        let spendableBalance = UInt64(spendableOnchainBalanceSats)

        availableUtxos = try await lightningService.listSpendableOutputs()

        // Use LDK-Node's special handling - when we pass the spendable balance as amount,
        // it will automatically calculate the fee for sending all available funds
        // if the exact amount would result in insufficient funds due to fees
        let fee = try await lightningService.calculateTotalFee(
            address: address,
            amountSats: spendableBalance,
            satsPerVByte: satsPerVByte,
            utxosToSpend: availableUtxos
        )

        // The max sendable amount is the spendable balance minus the fee
        return spendableBalance >= fee ? spendableBalance - fee : 0
    }

    /// Estimates the routing fees for a lightning payment
    func estimateRoutingFees(bolt11: String, amountSats: UInt64? = nil) async throws -> UInt64 {
        return try await lightningService.estimateRoutingFees(bolt11: bolt11, amountSats: amountSats)
    }

    /// Sends a lightning payment and waits for the result using async/await
    /// A LN payment can throw an error right away, be successful right away,
    /// or take a while to complete/fail because it's retrying different paths.
    /// So we need to handle all these cases here.
    func send(bolt11: String, sats: UInt64? = nil) async throws -> PaymentHash {
        let hash = try await lightningService.send(bolt11: bolt11, sats: sats)
        let eventId = String(hash)

        return try await withCheckedThrowingContinuation { continuation in
            // Add event listener for this specific payment
            addOnEvent(id: eventId) { event in
                switch event {
                case let .paymentSuccessful(_, paymentHash, _, _):
                    if paymentHash == hash {
                        self.removeOnEvent(id: eventId)
                        continuation.resume(returning: paymentHash)
                    }
                case .paymentFailed(paymentId: _, let paymentHash, let reason):
                    // TODO: this is not working for routeNotFound
                    if paymentHash == hash {
                        self.removeOnEvent(id: eventId)
                        continuation.resume(throwing: NSError(
                            domain: "Lightning",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: reason.debugDescription]
                        ))
                    }
                default:
                    break
                }
            }

            syncState()
        }
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

        // Update balance state with pending transfers
        Task { @MainActor in
            await updateBalanceState()
        }
    }

    /// Updates the balance state including pending transfers
    func updateBalanceState() async {
        do {
            let state = try await balanceManager.deriveBalanceState()
            balanceInTransferToSavings = Int(state.balanceInTransferToSavings)
            balanceInTransferToSpending = Int(state.balanceInTransferToSpending)

            // Update display values with adjusted balances
            totalOnchainSats = Int(state.totalOnchainSats)
            totalLightningSats = Int(state.totalLightningSats)
            totalBalanceSats = Int(state.totalBalanceSats)
            maxSendLightningSats = Int(state.maxSendLightningSats)
        } catch {
            Logger.error("Failed to update balance state: \(error)", context: "WalletViewModel")
        }
    }

    var totalInboundLightningSats: UInt64? {
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

        if channels?.count ?? 0 > 0 {
            if forceRefreshBolt11 || bolt11.isEmpty {
                bolt11 = try await createInvoice(amountSats: amountSats, note: invoiceNote)
            } else {
                // Existing invoice needs to be checked for expiry
                if case let .lightning(lightningInvoice) = try await decode(invoice: bolt11) {
                    if lightningInvoice.isExpired {
                        bolt11 = try await createInvoice(amountSats: amountSats, note: invoiceNote)
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
            let formattedAmount = Self.formatBitcoinAmount(sats: invoiceAmountSats)
            newBip21 += "\(separator)amount=\(formattedAmount)"
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
                guard let self else { return }
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

    /// Formats satoshi amount to Bitcoin decimal format for BIP21 URIs
    /// - Parameter sats: Amount in satoshis
    /// - Returns: Formatted Bitcoin amount as string (e.g., "0.00123000")
    static func formatBitcoinAmount(sats: UInt64) -> String {
        let btcAmount = Double(sats) / 100_000_000.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        formatter.decimalSeparator = "."
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: btcAmount)) ?? "0"
    }

    func resetSendState(speed: TransactionSpeed) {
        sendAmountSats = nil
        selectedFeeRateSatsPerVByte = nil
        selectedUtxos = nil
        availableUtxos = []
        selectedSpeed = speed
        isMaxAmountSend = false
    }

    func wipe() async throws {
        Logger.warn("Starting wallet wipe", context: "WalletViewModel")
        _ = await waitForNodeToRun(timeoutSeconds: 5.0)

        if nodeLifecycleState == .starting || nodeLifecycleState == .running {
            try await stopLightningNode()
        }

        try await lightningService.wipeStorage(walletIndex: 0)

        // Reset AppStorage display values
        totalBalanceSats = 0
        totalOnchainSats = 0
        totalLightningSats = 0
        maxSendLightningSats = 0
        channelCount = 0

        onchainAddress = ""
        bolt11 = ""
        bip21 = ""

        try? await coreService.activity.removeAll()

        try setWalletExistsState()

        Logger.warn("Wallet wipe completed", context: "WalletViewModel")
    }
}
