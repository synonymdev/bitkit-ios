import BitkitCore
import Foundation
import LDKNode

/// Thin wrapper around the bitkit-core Boltz swaps FFI (submarine + reverse swaps
/// between onchain Bitcoin and Lightning).
///
/// Mirrors the existing service pattern (e.g. `CoreService`): a singleton that wraps
/// the FFI through `ServiceQueue` and bridges the `BoltzEventListener` foreign
/// callback to `AsyncStream`s. bitkit-core persists only a derivation index, never
/// key material; swap keys are re-derived on demand from the wallet mnemonic.
///
/// The Lightning side (paying invoices, fresh onchain addresses) is owned by
/// `LightningService`; this service only talks to Boltz + the chain.
class BoltzService {
    static let shared = BoltzService()

    private let continuationsLock = NSLock()
    private var continuations: [UUID: AsyncStream<BoltzSwapEvent>.Continuation] = [:]

    private lazy var listener = EventForwarder { [weak self] event in
        Logger.info("Boltz event: \(event)", context: "BoltzService")
        self?.emit(event)
    }

    private init() {}

    // MARK: - Events

    /// Swap lifecycle events emitted while the updates stream is running. Each call
    /// returns an independent stream; events are buffered from the moment the stream
    /// is created, so subscribe before triggering the action whose events you await.
    func events() -> AsyncStream<BoltzSwapEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuationsLock.lock()
            continuations[id] = continuation
            continuationsLock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                continuationsLock.lock()
                continuations.removeValue(forKey: id)
                continuationsLock.unlock()
            }
        }
    }

    private func emit(_ event: BoltzSwapEvent) {
        continuationsLock.lock()
        let targets = Array(continuations.values)
        continuationsLock.unlock()

        for continuation in targets {
            continuation.yield(event)
        }
    }

    // MARK: - Limits

    func submarineLimits() async throws -> BoltzPairInfo {
        try await ServiceQueue.background(.core) {
            try await boltzGetSubmarineLimits(network: Self.boltzNetwork)
        }
    }

    func reverseLimits() async throws -> BoltzPairInfo {
        try await ServiceQueue.background(.core) {
            try await boltzGetReverseLimits(network: Self.boltzNetwork)
        }
    }

    // MARK: - Create

    /// Submarine swap: onchain BTC -> Lightning. Fund the returned lockup address.
    func createSubmarineSwap(invoice: String) async throws -> SubmarineSwapResponse {
        let (mnemonic, passphrase) = try credentials()
        let response = try await ServiceQueue.background(.core) {
            try await boltzCreateSubmarineSwap(
                network: Self.boltzNetwork,
                electrumUrl: Env.electrumServerUrl,
                invoice: invoice,
                mnemonic: mnemonic,
                bip39Passphrase: passphrase
            )
        }
        Logger.info("Created Boltz submarine swap \(response.id)", context: "BoltzService")
        return response
    }

    /// Reverse swap: Lightning -> onchain BTC. Pay the returned hold invoice.
    func createReverseSwap(amountSat: UInt64, claimAddress: String) async throws -> ReverseSwapResponse {
        let (mnemonic, passphrase) = try credentials()
        let response = try await ServiceQueue.background(.core) {
            try await boltzCreateReverseSwap(
                network: Self.boltzNetwork,
                electrumUrl: Env.electrumServerUrl,
                amountSat: amountSat,
                claimAddress: claimAddress,
                mnemonic: mnemonic,
                bip39Passphrase: passphrase
            )
        }
        Logger.info("Created Boltz reverse swap \(response.id)", context: "BoltzService")
        return response
    }

    // MARK: - Query

    func listSwaps() async throws -> [BoltzSwap] {
        try await ServiceQueue.background(.core) {
            try await boltzListSwaps()
        }
    }

    func listPendingSwaps() async throws -> [BoltzSwap] {
        try await ServiceQueue.background(.core) {
            try await boltzListPendingSwaps()
        }
    }

    func getSwap(id: String) async throws -> BoltzSwap? {
        try await ServiceQueue.background(.core) {
            try await boltzGetSwap(swapId: id)
        }
    }

    // MARK: - Manual claim / refund

    func claimReverseSwap(id: String, feeRateSatPerVb: Double? = nil) async throws -> String {
        let (mnemonic, passphrase) = try credentials()
        return try await ServiceQueue.background(.core) {
            try await boltzClaimReverseSwap(
                swapId: id,
                mnemonic: mnemonic,
                bip39Passphrase: passphrase,
                feeRateSatPerVb: feeRateSatPerVb
            )
        }
    }

    func refundSubmarineSwap(id: String, refundAddress: String, feeRateSatPerVb: Double? = nil) async throws -> String {
        let (mnemonic, passphrase) = try credentials()
        return try await ServiceQueue.background(.core) {
            try await boltzRefundSubmarineSwap(
                swapId: id,
                refundAddress: refundAddress,
                mnemonic: mnemonic,
                bip39Passphrase: passphrase,
                feeRateSatPerVb: feeRateSatPerVb
            )
        }
    }

    // MARK: - Updates stream

    /// Open the Boltz updates WebSocket, subscribe all pending swaps and auto-claim
    /// confirmed reverse swaps. `feeRateSatPerVb` is the rate used for those
    /// auto-claims (Bitkit owns fee estimation). Replaces any running stream.
    func startUpdates(feeRateSatPerVb: Double?) async throws {
        let (mnemonic, passphrase) = try credentials()
        try await ServiceQueue.background(.core) {
            try await boltzStartSwapUpdates(
                network: Self.boltzNetwork,
                listener: self.listener,
                mnemonic: mnemonic,
                bip39Passphrase: passphrase,
                feeRateSatPerVb: feeRateSatPerVb
            )
        }
        Logger.info("Started Boltz updates stream on \(Self.boltzNetwork)", context: "BoltzService")
    }

    func stopUpdates() async {
        await boltzStopSwapUpdates()
        Logger.info("Stopped Boltz updates stream", context: "BoltzService")
    }

    // MARK: - Helpers

    /// The Boltz network matching the app's configured network.
    static var boltzNetwork: BoltzNetwork {
        switch Env.network {
        case .bitcoin: return .mainnet
        case .testnet: return .testnet
        case .regtest: return .regtest
        // Boltz does not operate on signet; fall back to testnet for development.
        default: return .testnet
        }
    }

    private func credentials() throws -> (mnemonic: String, passphrase: String?) {
        let walletIndex = LightningService.shared.currentWalletIndex
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphraseRaw = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw
        return (mnemonic, passphrase)
    }
}

/// Bridges the UniFFI foreign callback to the service's event streams.
private final class EventForwarder: BoltzEventListener {
    private let handler: @Sendable (BoltzSwapEvent) -> Void

    init(handler: @escaping @Sendable (BoltzSwapEvent) -> Void) {
        self.handler = handler
    }

    func onEvent(event: BoltzSwapEvent) {
        handler(event)
    }
}

extension BoltzSwap {
    /// Whether a manual claim can succeed for this swap: reverse direction, lockup funds
    /// visible on-chain (mempool or confirmed), and no claim broadcast yet. Freshly created,
    /// expired, failed, and refunded swaps have nothing to claim.
    var isClaimable: Bool {
        guard swapType == .reverse, claimTxId == nil else { return false }
        switch status {
        case .transactionMempool, .transactionConfirmed, .transactionClaimPending:
            return true
        default:
            return false
        }
    }
}
