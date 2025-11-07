import BitkitCore
import Combine
import Foundation
import LDKNode

// TODO: catch all errors and pass a readable error message to the UI

class LightningService {
    private var node: Node?
    var currentWalletIndex: Int = 0
    private var currentLogFilePath: String?

    private let syncStatusChangedSubject = PassthroughSubject<UInt64, Never>()

    private var channelCache: [String: ChannelDetails] = [:]

    var syncStatusChangedPublisher: AnyPublisher<UInt64, Never> {
        syncStatusChangedSubject.eraseToAnyPublisher()
    }

    static var shared = LightningService()

    private init() {}

    func setup(walletIndex: Int, electrumServerUrl: String? = nil, rgsServerUrl: String? = nil) async throws {
        Logger.debug("Checking lightning process lock...")
        try StateLocker.lock(.lightning, wait: 30) // Wait 30 seconds to lock because maybe extension is still running

        guard var mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }

        var passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))

        currentWalletIndex = walletIndex

        var config = defaultConfig()
        let ldkStoragePath = Env.ldkStorage(walletIndex: walletIndex).path
        config.storageDirPath = ldkStoragePath
        config.network = Env.network

        Logger.debug("Using LDK storage path: \(ldkStoragePath)")

        config.trustedPeers0conf = Env.trustedLnPeers.map(\.nodeId)
        config.anchorChannelsConfig = .init(
            trustedPeersNoReserve: Env.trustedLnPeers.map(\.nodeId),
            perChannelReserveSats: 1
        )

        let builder = Builder.fromConfig(config: config)

        Logger.info("LDK-node log path: \(ldkStoragePath)")

        let logFilePath = generateLogFilePath()
        currentLogFilePath = logFilePath
        builder.setFilesystemLogger(logFilePath: logFilePath, maxLogLevel: Env.ldkLogLevel)

        let resolvedElectrumServerUrl = electrumServerUrl ?? Env.electrumServerUrl

        if Env.isE2E {
            let electrumConfig = ElectrumSyncConfig(
                backgroundSyncConfig: .init(
                    onchainWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
                    lightningWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
                    feeRateCacheUpdateIntervalSecs: Env.walletSyncIntervalSecs
                )
            )
            builder.setChainSourceElectrum(serverUrl: resolvedElectrumServerUrl, config: electrumConfig)
        } else {
            // TODO: switch to electrum after syncing issues are fixed
            // let electrumConfig = ElectrumSyncConfig(
            //     backgroundSyncConfig: .init(
            //         onchainWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
            //         lightningWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
            //         feeRateCacheUpdateIntervalSecs: Env.walletSyncIntervalSecs
            //     )
            // )
            // builder.setChainSourceElectrum(serverUrl: electrumServerUrl, config: electrumConfig)
            let esploraConfig = EsploraSyncConfig(
                backgroundSyncConfig: .init(
                    onchainWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
                    lightningWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
                    feeRateCacheUpdateIntervalSecs: Env.walletSyncIntervalSecs
                )
            )
            builder.setChainSourceEsplora(serverUrl: Env.esploraServerUrl, config: esploraConfig)
        }

        // Configure gossip source from current settings
        configureGossipSource(builder: builder, rgsServerUrl: rgsServerUrl)

        builder.setEntropyBip39Mnemonic(mnemonic: mnemonic, passphrase: passphrase)

        Logger.debug("Building node...")
        let storeId = try await VssStoreIdProvider.shared.getVssStoreId(walletIndex: walletIndex)

        let vssUrl = Env.vssServerUrl
        let lnurlAuthServerUrl = Env.lnurlAuthServerUrl
        Logger.debug("Building ldk-node with vssUrl: '\(vssUrl)'")
        Logger.debug("Building ldk-node with lnurlAuthServerUrl: '\(lnurlAuthServerUrl)'")

        try await ServiceQueue.background(.ldk) {
            if !lnurlAuthServerUrl.isEmpty {
                self.node = try builder.buildWithVssStore(
                    vssUrl: vssUrl,
                    storeId: storeId,
                    lnurlAuthServerUrl: lnurlAuthServerUrl,
                    fixedHeaders: [:]
                )
            } else {
                self.node = try builder.buildWithVssStoreAndFixedHeaders(
                    vssUrl: vssUrl,
                    storeId: storeId,
                    fixedHeaders: [:]
                )
            }
        }

        Logger.info("LDK node setup")

        // Clear memory
        mnemonic = ""
        passphrase = nil
    }

    func restart(electrumServerUrl: String? = nil, rgsServerUrl: String? = nil) async throws {
        Logger.info("Restarting node with current configuration")

        // Stop the current node if it exists, ignore errors if already stopped
        if node != nil {
            do {
                try await stop()
            } catch {
                Logger.debug("Node was already stopped or failed to stop: \(error)")
                // Clear the node reference anyway
                node = nil
                try? StateLocker.unlock(.lightning)
            }
        }

        // Restart the node with the current configuration
        try await setup(walletIndex: currentWalletIndex, electrumServerUrl: electrumServerUrl, rgsServerUrl: rgsServerUrl)
        try await start()

        Logger.info("Node restarted successfully")
    }

    /// Pass onEvent when being used in the background to listen for payments, channels, closes, etc
    /// - Parameter onEvent: Triggered on any LDK node event
    func start(onEvent: ((Event) -> Void)? = nil) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        listenForEvents(onEvent: onEvent)

        Logger.debug("Starting node...")
        try await ServiceQueue.background(.ldk) {
            try node.start()
        }

        await refreshChannelCache()

        Logger.info("Node started")
    }

    private func refreshChannelCache() async {
        guard let node else { return }

        let channels = try? await ServiceQueue.background(.ldk) {
            node.listChannels()
        }

        await MainActor.run {
            channelCache = Dictionary(uniqueKeysWithValues: (channels ?? []).map { ($0.channelId.description, $0) })
            Logger.debug("Refreshed channel cache: \(channelCache.count) channels", context: "LightningService")
        }
    }

    func stop() async throws {
        defer {
            // Always try to unlock, even if stopping fails
            try? StateLocker.unlock(.lightning)
        }

        guard let node else {
            Logger.warn("Node not started, nothing to stop")
            return
        }

        Logger.debug("Stopping node...")
        try await ServiceQueue.background(.ldk) {
            try node.stop()
        }
        self.node = nil

        await MainActor.run {
            channelCache.removeAll()
        }

        Logger.info("Node stopped")
    }

    func wipeStorage(walletIndex: Int) async throws {
        guard node == nil else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        let directory = Env.ldkStorage(walletIndex: walletIndex)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Logger.warn("No directory found to wipe: \(directory.path)")
            return
        }

        Logger.warn("Wiping on lighting wallet...")
        try FileManager.default.removeItem(at: directory)
        Logger.info("Lightning wallet wiped")
    }

    func connectToTrustedPeers() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        try await ServiceQueue.background(.ldk) {
            for peer in Env.trustedLnPeers {
                do {
                    try node.connect(nodeId: peer.nodeId, address: peer.address, persist: true)
                    Logger.info("Connected to trusted peer: \(peer.nodeId)")
                } catch {
                    Logger.error(error, context: "Peer: \(peer.nodeId)")
                }
            }
        }
    }

    /// Temp fix for regtest where nodes might not agree on current fee rates
    private func setMaxDustHtlcExposureForCurrentChannels() throws {
        guard Env.network == .regtest else {
            Logger.debug("Not updating channel config for non-regtest network")
            return
        }

        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        for channel in node.listChannels() {
            var config = channel.config
            config.maxDustHtlcExposure = .fixedLimit(limitMsat: 999_999 * 1000)
            try? node.updateChannelConfig(userChannelId: channel.userChannelId, counterpartyNodeId: channel.counterpartyNodeId, channelConfig: config)
            Logger.info("Updated channel config for: \(channel.userChannelId)")
        }
    }

    func sync() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        Logger.debug("Syncing LDK...")
        try await ServiceQueue.background(.ldk) {
            try node.syncWallets()
            // try? self.setMaxDustHtlcExposureForCurrentChannels()
        }
        Logger.info("LDK synced")

        await refreshChannelCache()

        // Emit state change with sync timestamp from node status
        let nodeStatus = node.status()
        if let latestSyncTimestamp = nodeStatus.latestLightningWalletSyncTimestamp {
            let syncTimestamp = UInt64(latestSyncTimestamp)
            syncStatusChangedSubject.send(syncTimestamp)
        } else {
            let syncTimestamp = UInt64(Date().timeIntervalSince1970)
            syncStatusChangedSubject.send(syncTimestamp)
        }
    }

    func newAddress() async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().newAddress()
        }
    }

    func receive(amountSats: UInt64? = nil, description: String, expirySecs: UInt32 = 3600) async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        let bolt11 = try await ServiceQueue.background(.ldk) {
            if let amountSats {
                try node
                    .bolt11Payment()
                    .receive(
                        amountMsat: amountSats * 1000,
                        description: Bolt11InvoiceDescription.direct(description: description),
                        expirySecs: expirySecs
                    )
            } else {
                try node
                    .bolt11Payment()
                    .receiveVariableAmount(
                        description: Bolt11InvoiceDescription.direct(description: description),
                        expirySecs: expirySecs
                    )
            }
        }

        return bolt11.description
    }

    /// Checks if we have the correct outbound capacity to send the amount
    /// - Parameter amountSats
    /// - Returns: True if we can send the amount
    func canSend(amountSats: UInt64) -> Bool {
        guard let channels else {
            Logger.warn("Channels not available")
            return false
        }

        let totalNextOutboundHtlcLimitSats =
            channels
                .filter(\.isUsable)
                .map(\.nextOutboundHtlcLimitMsat)
                .reduce(0, +) * 1000

        guard totalNextOutboundHtlcLimitSats > amountSats else {
            Logger.warn("Insufficient outbound capacity: \(totalNextOutboundHtlcLimitSats) < \(amountSats)")
            return false
        }

        return true
    }

    private static func convertVByteToKwu(satsPerVByte: UInt32) -> FeeRate {
        // 1 vbyte = 4 weight units, so 1 sats/vbyte = 250 sats/kwu
        let satPerKwu = UInt64(satsPerVByte * 250)
        // Ensure we're above the minimum relay fee
        return .fromSatPerKwu(satKwu: max(satPerKwu, 253)) // FEERATE_FLOOR_SATS_PER_KW is 253 in LDK
    }

    func send(
        address: String,
        sats: UInt64,
        satsPerVbyte: UInt32,
        utxosToSpend: [SpendableUtxo]? = nil,
        isMaxAmount: Bool = false
    ) async throws -> Txid {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        Logger.info("Sending \(sats) sats to \(address) with fee rate \(satsPerVbyte) sats/vbyte (isMaxAmount: \(isMaxAmount))")

        do {
            return try await ServiceQueue.background(.ldk) {
                if isMaxAmount {
                    // For max amount sends, use sendAllToAddress to send all available funds
                    try node.onchainPayment().sendAllToAddress(
                        address: address,
                        retainReserve: true,
                        feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte)
                    )
                } else {
                    // For normal sends, use sendToAddress with specific amount
                    try node.onchainPayment().sendToAddress(
                        address: address,
                        amountSats: sats,
                        feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte),
                        utxosToSpend: utxosToSpend
                    )
                }
            }
        } catch {
            dumpLdkLogs()
            throw error
        }
    }

    func send(bolt11: String, sats: UInt64? = nil, params: SendingParameters? = nil) async throws -> PaymentHash {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        Logger.info("Paying bolt11: \(bolt11)")

        do {
            return try await ServiceQueue.background(.ldk) {
                if let sats {
                    try node.bolt11Payment().sendUsingAmount(
                        invoice: .fromStr(invoiceStr: bolt11), amountMsat: sats * 1000, sendingParameters: params
                    )
                } else {
                    try node.bolt11Payment().send(invoice: .fromStr(invoiceStr: bolt11), sendingParameters: params)
                }
            }
        } catch {
            dumpLdkLogs()
            throw error
        }
    }

    func closeChannel(userChannelId: ChannelId, counterpartyNodeId: PublicKey) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.closeChannel(
                userChannelId: userChannelId,
                counterpartyNodeId: counterpartyNodeId
            )
        }
    }

    func closeChannel(_ channel: ChannelDetails) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.closeChannel(
                userChannelId: channel.userChannelId,
                counterpartyNodeId: channel.counterpartyNodeId
            )
        }
    }

    func sign(message: String) async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        guard let msg = message.data(using: .utf8) else {
            throw AppError(serviceError: .invalidNodeSigningMessage)
        }

        return try await ServiceQueue.background(.ldk) {
            node.signMessage(msg: [UInt8](msg))
        }
    }

    func openChannel(peer: LnPeer, channelAmountSats: UInt64, pushToCounterpartySats: UInt64? = nil, channelConfig: ChannelConfig? = nil) async throws
        -> UserChannelId
    {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.openChannel(
                nodeId: peer.nodeId,
                address: peer.address,
                channelAmountSats: channelAmountSats,
                pushToCounterpartyMsat: pushToCounterpartySats == nil ? nil : pushToCounterpartySats! * 1000,
                channelConfig: channelConfig
            )
        }
    }

    func dumpLdkLogs() {
        guard let logFilePath = currentLogFilePath else {
            Logger.error("No log file path available")
            return
        }

        let fileURL = URL(fileURLWithPath: logFilePath)

        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            print("*****LDK-NODE LOG******")
            for line in lines.suffix(20) {
                print(line)
            }
        } catch {
            Logger.error(error, context: "failed to load ldk log file: \(logFilePath)")
        }
    }

    // MARK: Logging helpers

    private func generateLogFilePath() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        let timestamp = dateFormatter.string(from: Date())

        let baseDir = Env.logDirectory
        let contextPrefix = Env.currentExecutionContext.filenamePrefix
        let logFilePath = "\(baseDir)/ldk_\(contextPrefix)_\(timestamp).log"

        // Create directory if it doesn't exist
        let directory = URL(fileURLWithPath: baseDir)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                Logger.error("Failed to create log directory: \(error)")
            }
        }

        Logger.debug("Generated LDK log file path: \(logFilePath)")
        return logFilePath
    }

    // MARK: - Configuration Helpers

    private func configureGossipSource(builder: Builder, rgsServerUrl: String?) {
        let rgsUrl = rgsServerUrl ?? Env.ldkRgsServerUrl
        if let rgsUrl, !rgsUrl.isEmpty {
            Logger.info("Using gossip source rgs url: \(rgsUrl)")
            builder.setGossipSourceRgs(rgsServerUrl: rgsUrl)
        } else {
            Logger.info("Using gossip source p2p")
            builder.setGossipSourceP2p()
        }
    }
}

// MARK: UI Helpers (Published via WalletViewModel)

extension LightningService {
    var nodeId: String? { node?.nodeId() }
    var balances: BalanceDetails? { node?.listBalances() }
    var status: NodeStatus? { node?.status() }
    var peers: [PeerDetails]? { node?.listPeers() }
    var channels: [ChannelDetails]? { node?.listChannels() }
    var payments: [PaymentDetails]? { node?.listPayments() }
}

// MARK: Events

extension LightningService {
    func listenForEvents(onEvent: ((Event) -> Void)? = nil) {
        Task {
            while true {
                guard let node = self.node else {
                    Logger.error("LDK node not started")
                    return
                }

                let event = await node.nextEventAsync()

                do {
                    try node.eventHandled()
                } catch {
                    Logger.error(error, context: "node.eventHandled()")
                }

                onEvent?(event)

                // TODO: actual event handler
                switch event {
                case let .paymentSuccessful(paymentId, paymentHash, paymentPreimage, feePaidMsat):
                    Logger.info("✅ Payment successful: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) feePaidMsat: \(feePaidMsat ?? 0)")
                case let .paymentFailed(paymentId, paymentHash, reason):
                    Logger.info(
                        "❌ Payment failed: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash ?? "") reason: \(reason.debugDescription)"
                    )
                case let .paymentReceived(paymentId, paymentHash, amountMsat, feePaidMsat):
                    Logger.info("🤑 Payment received: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) amountMsat: \(amountMsat)")
                case let .paymentClaimable(paymentId, paymentHash, claimableAmountMsat, claimDeadline, customRecords):
                    Logger.info(
                        "🫰 Payment claimable: paymentId: \(paymentId) paymentHash: \(paymentHash) claimableAmountMsat: \(claimableAmountMsat)"
                    )
                case let .channelPending(channelId, userChannelId, formerTemporaryChannelId, counterpartyNodeId, fundingTxo):
                    Logger.info(
                        "⏳ Channel pending: channelId: \(channelId) userChannelId: \(userChannelId) formerTemporaryChannelId: \(formerTemporaryChannelId) counterpartyNodeId: \(counterpartyNodeId) fundingTxo: \(fundingTxo)"
                    )
                case let .channelReady(channelId, userChannelId, counterpartyNodeId):
                    Logger.info(
                        "👐 Channel ready: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?")"
                    )
                case let .channelClosed(channelId, userChannelId, counterpartyNodeId, reason):
                    let reasonString = reason.map { String(describing: $0) } ?? ""
                    Logger.info(
                        "⛔ Channel closed: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?") reason: \(reasonString)"
                    )

                    let channelIdString = channelId.description
                    let channel = await MainActor.run {
                        channelCache[channelIdString]
                    }

                    if let channel {
                        await registerClosedChannel(channel: channel, reason: reasonString)
                    } else {
                        Logger.error("Could not find channel details for closed channel: \(userChannelId) in cache", context: "LightningService")
                    }
                case .paymentForwarded:
                    break
                }

                await refreshChannelCache()
            }
        }
    }

    private func registerClosedChannel(
        channel: ChannelDetails,
        reason: String
    ) async {
        do {
            let channelName: String
            if let scidAlias = channel.inboundScidAlias {
                channelName = String(scidAlias)
            } else {
                let channelIdString = channel.channelId.description
                let prefix = String(channelIdString.prefix(10))
                channelName = "\(prefix)…"
            }

            guard let fundingTxo = channel.fundingTxo else {
                Logger.error("Channel has no funding transaction", context: "LightningService")
                return
            }

            let closedChannel = ClosedChannelDetails(
                channelId: channel.channelId.description,
                counterpartyNodeId: channel.counterpartyNodeId.description,
                fundingTxoTxid: fundingTxo.txid.description,
                fundingTxoIndex: fundingTxo.vout,
                channelValueSats: channel.channelValueSats,
                closedAt: UInt64(Date().timeIntervalSince1970),
                outboundCapacityMsat: channel.outboundCapacityMsat,
                inboundCapacityMsat: channel.inboundCapacityMsat,
                counterpartyUnspendablePunishmentReserve: channel.counterpartyUnspendablePunishmentReserve,
                unspendablePunishmentReserve: channel.unspendablePunishmentReserve ?? 0,
                forwardingFeeProportionalMillionths: channel.config.forwardingFeeProportionalMillionths,
                forwardingFeeBaseMsat: channel.config.forwardingFeeBaseMsat,
                channelName: channelName,
                channelClosureReason: reason
            )

            try await CoreService.shared.activity.upsertClosedChannel(closedChannel)
            Logger.info("Registered closed channel: \(channel.userChannelId)", context: "LightningService")
        } catch {
            Logger.error("Failed to register closed channel: \(error)", context: "LightningService")
        }
    }
}

// MARK: UTXO selection

extension LightningService {
    func listSpendableOutputs() async throws -> [SpendableUtxo] {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().listSpendableOutputs()
        }
    }

    func selectUtxosWithAlgorithm(
        targetAmountSats: UInt64, satsPerVbyte: UInt32, coinSelectionAlgorythm: CoinSelectionAlgorithm, utxos: [SpendableUtxo]?
    ) async throws -> [SpendableUtxo] {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .selectUtxosWithAlgorithm(
                    targetAmountSats: targetAmountSats,
                    feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte),
                    algorithm: coinSelectionAlgorythm,
                    utxos: utxos
                )
        }
    }
}

// MARK: Boost txs

extension LightningService {
    func bumpFeeByRbf(txid: String, satsPerVbyte: UInt32) async throws -> Txid {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .bumpFeeByRbf(
                    txid: txid,
                    feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte)
                )
        }
    }

    func accelerateByCpfp(txid: String, satsPerVbyte: UInt32? = nil, destinationAddress: String? = nil) async throws -> Txid {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .accelerateByCpfp(
                    txid: txid,
                    feeRate: satsPerVbyte != nil ? Self.convertVByteToKwu(satsPerVByte: satsPerVbyte!) : nil,
                    destinationAddress: destinationAddress
                )
        }
    }

    func calculateCpfpFeeRate(parentTxid: String, urgent: Bool) async throws -> FeeRate {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .calculateCpfpFeeRate(
                    parentTxid: parentTxid,
                    urgent: urgent
                )
        }
    }
}

// MARK: Fees

extension LightningService {
    /// Calculates the total fee for a transaction
    /// - Parameters:
    ///   - address: The destination address
    ///   - amountSats: The amount to send in satoshis
    ///   - satsPerVByte: The fee rate in satoshis per virtual byte
    ///   - utxosToSpend: Optional specific UTXOs to spend
    /// - Returns: The total fee in satoshis
    /// - Throws: ServiceError if node is not setup or calculation fails
    func calculateTotalFee(
        address: String,
        amountSats: UInt64,
        satsPerVByte: UInt32,
        utxosToSpend: [SpendableUtxo]? = nil
    ) async throws -> UInt64 {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let fee = try node.onchainPayment().calculateTotalFee(
                address: address,
                amountSats: amountSats,
                feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVByte),
                utxosToSpend: utxosToSpend
            )

            return fee
        }
    }

    func estimateRoutingFees(bolt11: String, amountSats: UInt64? = nil) async throws -> UInt64 {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let invoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
            let feesMsat: UInt64

            if let amountSats {
                let amountMsat = amountSats * 1000
                feesMsat = try node.bolt11Payment().estimateRoutingFeesUsingAmount(invoice: invoice, amountMsat: amountMsat)
            } else {
                feesMsat = try node.bolt11Payment().estimateRoutingFees(invoice: invoice)
            }

            let feeSat = feesMsat / 1000

            return feeSat
        }
    }
}
