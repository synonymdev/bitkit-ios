import BitkitCore
import Foundation

/// Watcher-related service calls, extracted as a protocol so unit tests can
/// substitute a mock.
protocol OnChainWatcherServicing {
    func startWatcher(params: WatcherParams, listener: EventListener) async throws
    func stopWatcher(watcherId: String) throws
    func stopAllWatchers()
}

extension OnChainHwService: OnChainWatcherServicing {}

/// Vendor-neutral on-chain service layer. Wraps the device-less `onchain*` BitkitCore FFI
/// functions — account/address info, transaction history/detail, transaction composition and
/// broadcasting, and the Electrum event watcher. None of these require a connected hardware
/// device; they query Electrum directly. Shared by all consumers (`HwWalletManager`,
/// `TrezorViewModel`, …) so the watch-only layer depends on this rather than `TrezorService`.
/// All operations run on ServiceQueue.background(.core) to ensure thread safety.
class OnChainHwService {
    static let shared = OnChainHwService()

    private init() {}

    // MARK: - Account/Address Info (No Device Required)

    /// Get account info (balance, UTXOs) for an extended public key (xpub/ypub/zpub/tpub/upub/vpub).
    /// This does NOT require a connected Trezor device — it queries the Electrum server directly.
    func getAccountInfo(
        extendedKey: String,
        electrumUrl: String,
        network: TrezorCoinType? = nil,
        gapLimit: UInt32? = nil,
        scriptType: AccountType? = nil
    ) async throws -> AccountInfoResult {
        let networkParam = network?.coreNetwork
        return try await ServiceQueue.background(.core) {
            try await onchainGetAccountInfo(
                extendedKey: extendedKey,
                electrumUrl: electrumUrl,
                network: networkParam,
                gapLimit: gapLimit,
                scriptType: scriptType
            )
        }
    }

    /// Get address info (balance, UTXOs) for a single Bitcoin address.
    /// This does NOT require a connected Trezor device — it queries the Electrum server directly.
    func getAddressInfo(
        address: String,
        electrumUrl: String,
        network: TrezorCoinType? = nil
    ) async throws -> SingleAddressInfoResult {
        let networkParam = network?.coreNetwork
        return try await ServiceQueue.background(.core) {
            try await onchainGetAddressInfo(
                address: address,
                electrumUrl: electrumUrl,
                network: networkParam
            )
        }
    }

    // MARK: - Transaction History & Detail (No Device Required)

    /// Get transaction history for an extended public key (xpub/ypub/zpub/tpub/upub/vpub).
    /// This does NOT require a connected Trezor device — it queries the Electrum server directly.
    func getTransactionHistory(
        extendedKey: String,
        electrumUrl: String,
        network: TrezorCoinType? = nil,
        scriptType: AccountType? = nil
    ) async throws -> TransactionHistoryResult {
        let networkParam = network?.coreNetwork
        return try await ServiceQueue.background(.core) {
            try await onchainGetTransactionHistory(
                extendedKey: extendedKey,
                electrumUrl: electrumUrl,
                network: networkParam,
                scriptType: scriptType
            )
        }
    }

    /// Get detailed information for a specific transaction by its ID.
    /// This does NOT require a connected Trezor device — it queries the Electrum server directly.
    func getTransactionDetail(
        extendedKey: String,
        electrumUrl: String,
        txid: String,
        network: TrezorCoinType? = nil,
        scriptType: AccountType? = nil
    ) async throws -> TransactionDetail {
        let networkParam = network?.coreNetwork
        return try await ServiceQueue.background(.core) {
            try await onchainGetTransactionDetail(
                extendedKey: extendedKey,
                electrumUrl: electrumUrl,
                txid: txid,
                network: networkParam,
                scriptType: scriptType
            )
        }
    }

    // MARK: - Transaction Composition & Broadcasting

    /// Compose a transaction using BDK-based PSBT generation (signer-agnostic).
    /// Does NOT require a connected Trezor device.
    func composeTransaction(params: ComposeParams) async throws -> [ComposeResult] {
        try await ServiceQueue.background(.core) {
            await onchainComposeTransaction(params: params)
        }
    }

    /// Broadcast a signed raw transaction via Electrum.
    /// - Returns: The transaction ID (txid)
    func broadcastRawTx(serializedTx: String, electrumUrl: String) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await onchainBroadcastRawTx(serializedTx: serializedTx, electrumUrl: electrumUrl)
        }
    }

    // MARK: - Event Watcher (No Device Required)

    /// Start watching an extended public key for on-chain transaction activity.
    /// Events are delivered to `listener` until the watcher is stopped.
    /// Does NOT require a connected Trezor device — it subscribes to Electrum directly.
    func startWatcher(params: WatcherParams, listener: EventListener) async throws {
        try await ServiceQueue.background(.core) {
            try await onchainStartWatcher(params: params, listener: listener)
        }
    }

    /// Stop a specific watcher by its id.
    func stopWatcher(watcherId: String) throws {
        try onchainStopWatcher(watcherId: watcherId)
    }

    /// Stop all active watchers.
    func stopAllWatchers() {
        onchainStopAllWatchers()
    }
}

// MARK: - Network / Electrum helpers

/// Network- and Electrum-derivation helpers shared by all on-chain consumers (`TrezorManager`,
/// `TrezorViewModel`, `HwWalletManager`). They live on the service layer so feature managers
/// don't reference each other for plain network/electrum configuration.
extension OnChainHwService {
    /// The app's global network mapped to a `TrezorCoinType`.
    static var appDefaultCoinType: TrezorCoinType {
        switch Env.network {
        case .bitcoin: .bitcoin
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }

    /// BIP44 coin-type component for the app's global network: "0'" mainnet, "1'" test networks.
    static var defaultCoinTypeComponent: String {
        Env.network == .bitcoin ? "0'" : "1'"
    }

    /// Hardcoded Electrum server URL per network (with the regtest dev override).
    static func electrumUrlForNetwork(_ network: TrezorCoinType) -> String {
        if network == .regtest, let trezorElectrumUrl = Env.trezorElectrumUrl {
            return trezorElectrumUrl
        }
        switch network {
        case .bitcoin:
            return "ssl://bitkit.to:9999"
        case .testnet, .signet:
            return "ssl://electrum.blockstream.info:60002"
        case .regtest:
            return "ssl://electrs.bitkit.stag0.blocktank.to:9999"
        }
    }

    /// The app's configured Electrum server (falls back to the default).
    static func getElectrumUrl() -> String {
        let server = ElectrumConfigService().getCurrentServer()
        return server.fullUrl.isEmpty ? Env.electrumServerUrl : server.fullUrl
    }
}

extension TrezorCoinType {
    /// The BitkitCore `Network` this coin type maps to, used by the onchain FFI functions.
    var coreNetwork: BitkitCore.Network {
        switch self {
        case .bitcoin: .bitcoin
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }
}
