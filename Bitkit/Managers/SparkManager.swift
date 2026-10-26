import BigNumber
import BitkitCore
import BreezSdkSpark
import Foundation
import LDKNode
import Observation

/// Lightning without channels, through the Breez SDK on Spark. Savings to Spending funds this wallet,
/// receives fall back to it when no channel has the inbound capacity, and sends fall back to it when no
/// channel has the outbound capacity. Its keys derive from the Bitkit seed on Spark's own path (`m/8797555'`).
/// Its payments reach the app as LDK events through `LightningService.emitChannelFreeRailEvent`, so the
/// receive and send flows built on node events work for both rails.
@Observable @MainActor
final class SparkManager: ChannelFreeLightningRail {
    static let shared = SparkManager()

    private static let sendCompletionTimeoutSecs: UInt32 = 30
    private static let depositClaimFeeLeewaySatPerVbyte: UInt64 = 2
    private static let depositClaimFeePpm: UInt32 = 2000

    private(set) var isReady = false
    private(set) var balanceSats: UInt64 = 0
    /// Deposits seen on-chain that Spark claims into `balanceSats` after 3 confirmations.
    private(set) var pendingDepositSats: UInt64 = 0
    private(set) var recoverableFundsSats: UInt64 = 0
    /// Called when Spark claims on-chain deposits, which completes a Savings to Spending transfer.
    var onDepositsClaimed: (() -> Void)?
    /// Called after the Spark balance or readiness was read again, so balances and the receive invoice can follow.
    var onStateChanged: (() -> Void)?

    @ObservationIgnored private var sdk: BreezSdk?
    @ObservationIgnored private var listenerId: String?
    @ObservationIgnored private var connectTask: Task<Void, Error>?

    private init() {}

    var isSupported: Bool {
        Self.sparkNetwork != nil
    }

    private static var sparkNetwork: BreezSdkSpark.Network? {
        switch Env.network {
        case .bitcoin: Env.breezApiKey == nil ? nil : .mainnet
        case .regtest: .regtest
        default: nil
        }
    }

    func start(walletIndex: Int) async {
        guard let network = Self.sparkNetwork else { return }
        do {
            if sdk == nil {
                if connectTask == nil {
                    connectTask = Task { try await connect(walletIndex: walletIndex, network: network) }
                }
                try await connectTask?.value
                connectTask = nil
            }
            try await refresh()
            try await syncActivities()
            LightningService.shared.channelFreeRail = self
        } catch {
            connectTask = nil
            Logger.error("Failed to start Spark wallet: \(error)", context: "SparkManager")
        }
    }

    private func connect(walletIndex: Int, network: BreezSdkSpark.Network) async throws {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        var config = defaultConfig(network: network)
        config.apiKey = Env.breezApiKey
        config.maxDepositClaimFee = MaxFee(
            onchain: .networkRecommended(leewaySatPerVbyte: Self.depositClaimFeeLeewaySatPerVbyte),
            proportionalPpm: Self.depositClaimFeePpm
        )
        let storageDir = Env.sparkStorage(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        let connected = try await BreezSdkSpark.connect(request: ConnectRequest(
            config: config,
            seed: .mnemonic(mnemonic: mnemonic, passphrase: passphrase),
            storageDir: storageDir.path
        ))
        listenerId = await connected.addEventListener(listener: SparkEventListener { [weak self] event in
            await self?.onSdkEvent(event)
        })
        sdk = connected
        Logger.info("Connected Spark wallet on '\(network)'", context: "SparkManager")
    }

    func wipe(walletIndex: Int) async {
        if LightningService.shared.channelFreeRail === self {
            LightningService.shared.channelFreeRail = nil
        }
        if let sdk {
            if let listenerId {
                _ = await sdk.removeEventListener(id: listenerId)
            }
            try? await sdk.disconnect()
        }
        sdk = nil
        listenerId = nil
        isReady = false
        balanceSats = 0
        pendingDepositSats = 0
        recoverableFundsSats = 0
        try? FileManager.default.removeItem(at: Env.sparkStorage(walletIndex: walletIndex))
    }

    // MARK: ChannelFreeLightningRail

    nonisolated func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        let method = ReceivePaymentMethod.bolt11Invoice(
            description: description,
            amountSats: amountSats,
            expirySecs: expirySecs,
            paymentHash: nil,
            receiverIdentityPublicKey: nil
        )
        return try await requireSdk().receivePayment(request: ReceivePaymentRequest(paymentMethod: method)).paymentRequest
    }

    nonisolated func send(bolt11: String, sats: UInt64?) async throws -> PaymentHash {
        let prepared = try await prepareSend(paymentRequest: bolt11, amountSats: sats)
        guard case let .bolt11Invoice(invoiceDetails, _, _) = prepared.paymentMethod else {
            throw AppError(message: "Unexpected Spark payment method", debugMessage: "\(prepared.paymentMethod)")
        }
        let response = try await requireSdk().sendPayment(request: SendPaymentRequest(
            prepareResponse: prepared,
            options: .bolt11Invoice(preferSpark: false, completionTimeoutSecs: Self.sendCompletionTimeoutSecs)
        ))
        Logger.info("Sent Spark payment '\(response.payment.id)' with status '\(response.payment.status)'", context: "SparkManager")
        return invoiceDetails.paymentHash
    }

    nonisolated func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64 {
        let prepared = try await prepareSend(paymentRequest: bolt11, amountSats: amountSats)
        guard case let .bolt11Invoice(_, _, lightningFeeSats) = prepared.paymentMethod else { return 0 }
        return lightningFeeSats
    }

    // MARK: Transfers

    /// The static on-chain address that funds the Spark wallet, claimed automatically once confirmed.
    func depositAddress() async throws -> String {
        let request = ReceivePaymentRequest(paymentMethod: .bitcoinAddress(newAddress: nil))
        return try await requireSdk().receivePayment(request: request).paymentRequest
    }

    /// Moves the whole Spark balance to the on-chain `address`, fees included, for Spending to Savings.
    func withdrawAll(to address: String) async throws {
        let prepared = try await prepareSend(paymentRequest: address, amountSats: balanceSats, feePolicy: .feesIncluded)
        _ = try await requireSdk().sendPayment(request: SendPaymentRequest(
            prepareResponse: prepared,
            options: .bitcoinAddress(confirmationSpeed: .medium)
        ))
        try await refresh()
    }

    /// What a unilateral exit needs if the Spark operators stop cooperating; it can reach several MB.
    func exportExitState() async throws -> String {
        try await requireSdk().exportUnilateralExitState().exitState
    }

    // MARK: Private

    private nonisolated func prepareSend(
        paymentRequest: String,
        amountSats: UInt64?,
        feePolicy: FeePolicy? = nil
    ) async throws -> PrepareSendPaymentResponse {
        try await requireSdk().prepareSendPayment(request: PrepareSendPaymentRequest(
            paymentRequest: .input(input: paymentRequest),
            amount: amountSats.map { BInt(Int($0)) },
            tokenIdentifier: nil,
            conversionOptions: nil,
            feePolicy: feePolicy
        ))
    }

    private nonisolated func requireSdk() async throws -> BreezSdk {
        guard let sdk = await sdk else {
            throw AppError(message: "Spark wallet is not connected", debugMessage: nil)
        }
        return sdk
    }

    private func refresh() async throws {
        let sdk = try await requireSdk()
        let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: false))
        let deposits = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest())
        let pending = deposits.deposits.reduce(0) { $0 + $1.amountSats }
        let changed = !isReady || balanceSats != info.balanceSats || pendingDepositSats != pending
        isReady = true
        balanceSats = info.balanceSats
        pendingDepositSats = pending
        recoverableFundsSats = info.recoverableFundsSats
        if changed {
            onStateChanged?()
        }
    }

    private func syncActivities() async throws {
        let payments = try await requireSdk().listPayments(request: ListPaymentsRequest()).payments
        for payment in payments {
            await recordActivity(payment)
        }
    }

    private func onSdkEvent(_ event: SdkEvent) async {
        do {
            switch event {
            case .synced, .newDeposits:
                try await refresh()
            case .claimedDeposits:
                try await refresh()
                onDepositsClaimed?()
            case let .unclaimedDeposits(deposits):
                Logger.warn("Found '\(deposits.count)' unclaimed Spark deposits", context: "SparkManager")
            case let .paymentSucceeded(payment), let .paymentFailed(payment):
                try await refresh()
                await recordActivity(payment)
                if let event = Self.nodeEvent(for: payment) {
                    LightningService.shared.emitChannelFreeRailEvent(event)
                }
            case let .paymentPending(payment):
                await recordActivity(payment)
            default:
                break
            }
        } catch {
            Logger.error("Failed to handle Spark event '\(event)': \(error)", context: "SparkManager")
        }
    }

    private func recordActivity(_ payment: Payment) async {
        guard case let .lightning(description, invoice, _, htlcDetails, _, _, _, _) = payment.details else { return }
        if payment.status == .pending, payment.paymentType == .receive {
            return
        }
        let state: PaymentState = switch payment.status {
        case .completed: .succeeded
        case .pending: .pending
        case .failed: .failed
        }
        let activity = LightningActivity(
            walletId: WalletScope.default,
            id: htlcDetails.paymentHash,
            txType: payment.paymentType == .send ? .sent : .received,
            status: state,
            value: Self.sats(payment.amount),
            fee: Self.sats(payment.fees),
            invoice: invoice,
            message: description ?? "",
            timestamp: payment.timestamp,
            preimage: htlcDetails.preimage,
            contact: nil,
            createdAt: payment.timestamp,
            updatedAt: payment.timestamp,
            seenAt: nil
        )
        do {
            try await CoreService.shared.activity.upsert(.lightning(activity))
        } catch {
            Logger.error("Failed to record Spark payment '\(payment.id)': \(error)", context: "SparkManager")
        }
    }

    private static func nodeEvent(for payment: Payment) -> Event? {
        guard case let .lightning(_, _, _, htlcDetails, _, _, _, _) = payment.details else { return nil }
        let hash = htlcDetails.paymentHash
        switch (payment.paymentType, payment.status) {
        case (.receive, .completed):
            return .paymentReceived(paymentId: hash, paymentHash: hash, amountMsat: sats(payment.amount) * 1000, customRecords: [])
        case (.send, .completed):
            return .paymentSuccessful(
                paymentId: hash,
                paymentHash: hash,
                paymentPreimage: htlcDetails.preimage,
                feePaidMsat: sats(payment.fees) * 1000
            )
        case (.send, .failed):
            return .paymentFailed(paymentId: hash, paymentHash: hash, reason: .unexpectedError)
        default:
            return nil
        }
    }

    private static func sats(_ value: U128) -> UInt64 {
        UInt64(value.description) ?? 0
    }
}

private final class SparkEventListener: BreezSdkSpark.EventListener, @unchecked Sendable {
    private let handler: @Sendable (SdkEvent) async -> Void

    init(handler: @escaping @Sendable (SdkEvent) async -> Void) {
        self.handler = handler
    }

    func onEvent(event: SdkEvent) async {
        await handler(event)
    }
}
