import BitkitCore
import Foundation

/// Arkade's wallet and Lightning client for Bitkit: the Arkade module of bitkit-core, a Rust engine on
/// `arkade-os/rust-sdk` (ark-rs) shared with Android, which adds the Arkade Intents Lightning client the Rust SDK
/// lacks. It converts the core's records to the app's types below, which shadow the core types of the same name.
@MainActor
final class ArkadeBridge {
    var onEvent: ((ArkadeBridgeEvent) -> Void)?

    private var dataDir: String?

    init() {
        arkadeSetListener(listener: ArkadeListener { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        })
    }

    func start(_ params: ArkadeStartParams) async throws -> ArkadeInfo {
        let network: ArkadeNetwork = switch params.network {
        case "bitcoin": .bitcoin
        case "mutinynet": .mutinynet
        default: throw ArkadeError.unsupported
        }
        let info = try await arkadeStart(params: BitkitCore.ArkadeStartParams(
            dataDir: params.dataDir,
            mnemonic: params.mnemonic,
            passphrase: params.passphrase,
            network: network,
            restore: params.restore,
            backup: params.backup
        ))
        dataDir = params.dataDir
        return ArkadeInfo(info)
    }

    func info() async throws -> ArkadeInfo {
        try await ArkadeInfo(arkadeInfo())
    }

    func balance() async throws -> ArkadeBalance {
        try await ArkadeBalance(arkadeBalance())
    }

    func vtxos() async throws -> [ArkadeVtxo] {
        try await arkadeVtxos().map(ArkadeVtxo.init)
    }

    func history() async throws -> [ArkadeHistoryEntry] {
        try await arkadeHistory().map(ArkadeHistoryEntry.init)
    }

    func swaps() async throws -> [ArkadeSwap] {
        try await arkadeSwaps().map(ArkadeSwap.init)
    }

    func receive(amountSats: UInt64) async throws -> ArkadeSwap {
        try await ArkadeSwap(arkadeReceive(amountSat: amountSats))
    }

    func quotePay(bolt11: String) async throws -> ArkadePayQuote {
        try await ArkadePayQuote(feeSat: Int64(clamping: arkadeQuotePay(bolt11: bolt11).feeSat))
    }

    func pay(bolt11: String) async throws -> ArkadeSwap {
        try await ArkadeSwap(arkadePay(bolt11: bolt11, maxFeeSat: nil))
    }

    /// Moves the whole balance to `address` in the next batch; the commitment txid.
    func offboard(address: String) async throws -> String {
        try await arkadeOffboard(address: address, amountSat: nil)
    }

    func lightningAddress() async throws -> ArkadeLightningAddress? {
        let address = try await arkadeLightningAddress()
        return ArkadeLightningAddress(lightningAddress: address.lightningAddress, lnurl: address.lnurl)
    }

    func exportState() async throws -> String {
        guard let dataDir else { throw ArkadeError.notConnected }
        return try await Task.detached { try arkadeExportState(dataDir: dataDir) }.value
    }

    /// Stops the wallet and deletes its storage in `dataDir`.
    func wipe(dataDir: String) async throws {
        try await arkadeWipe(dataDir: dataDir)
        self.dataDir = nil
    }

    /// Stops the wallet, so the next `start` opens its storage again and imports a staged backup.
    func reload() async throws {
        await arkadeStop()
    }
}

enum ArkadeBridgeEvent {
    case swap(ArkadeSwap)
    case history([ArkadeHistoryEntry])
}

private final class ArkadeListener: ArkadeEventListener {
    private let send: @Sendable (ArkadeBridgeEvent) -> Void

    init(send: @escaping @Sendable (ArkadeBridgeEvent) -> Void) {
        self.send = send
    }

    func onHistory(entries: [BitkitCore.ArkadeHistoryEntry], balance _: BitkitCore.ArkadeBalance) {
        send(.history(entries.map(ArkadeHistoryEntry.init)))
    }

    func onSwap(swap: BitkitCore.ArkadeSwap) {
        send(.swap(ArkadeSwap(swap)))
    }
}

/// What `start` gets; the mnemonic and passphrase leave the app only inside this call.
struct ArkadeStartParams {
    /// The wallet's own storage directory.
    let dataDir: String
    let mnemonic: String
    let passphrase: String?
    /// `bitcoin` or `mutinynet`.
    let network: String
    let restore: Bool
    let backup: String?
}

struct ArkadeInfo {
    let arkAddress: String
    let boardingAddress: String
    let network: String
}

extension ArkadeInfo {
    init(_ info: BitkitCore.ArkadeInfo) {
        self.init(arkAddress: info.arkAddress, boardingAddress: info.boardingAddress, network: info.network)
    }
}

struct ArkadeBalance {
    var available: Int64 = 0
    var recoverable: Int64 = 0
    var boardingConfirmed: Int64 = 0
    var boardingUnconfirmed: Int64 = 0
}

extension ArkadeBalance {
    init(_ balance: BitkitCore.ArkadeBalance) {
        self.init(
            available: Int64(clamping: balance.available),
            recoverable: Int64(clamping: balance.recoverable),
            boardingConfirmed: Int64(clamping: balance.boardingConfirmed),
            boardingUnconfirmed: Int64(clamping: balance.boardingUnconfirmed)
        )
    }
}

struct ArkadeVtxo: Equatable {
    var txid: String?
    /// Unix seconds, or milliseconds, after which the operator may sweep this output unless it is renewed.
    var batchExpiry: Int64?
    var isSwept: Bool?
}

extension ArkadeVtxo {
    init(_ vtxo: BitkitCore.ArkadeVtxo) {
        self.init(txid: vtxo.txid, batchExpiry: vtxo.batchExpiry.map { Int64(clamping: $0) }, isSwept: vtxo.isSwept)
    }
}

struct ArkadeHistoryEntry: Equatable {
    static let received = "RECEIVED"
    static let sent = "SENT"

    var boardingTxid: String?
    var commitmentTxid: String?
    var arkTxid: String?
    /// `SENT` or `RECEIVED`.
    var type: String
    var amount: Int64
    var settled: Bool
    /// Unix milliseconds.
    var createdAt: Int64
}

extension ArkadeHistoryEntry {
    init(_ entry: BitkitCore.ArkadeHistoryEntry) {
        self.init(
            boardingTxid: entry.boardingTxid,
            commitmentTxid: entry.commitmentTxid,
            arkTxid: entry.arkTxid,
            type: entry.txType,
            amount: Int64(clamping: entry.amount),
            settled: entry.settled,
            createdAt: Int64(clamping: entry.createdAt)
        )
    }
}

/// A Lightning swap through Arkade Intents: `receive` pays into the wallet, `send` pays an invoice out of it.
struct ArkadeSwap: Equatable {
    static let claimed = "claimed"
    static let paid = "paid"
    static let failedSendOutcomes: Set<String> = ["refunded", "cancelled", "failed"]

    var id: String?
    var direction: String?
    var outcome: String?
    var takeSat: Int64?
    var feeSat: Int64?
    var bolt11: String?
    var paymentHash: String?
    /// Unix seconds.
    var createdAt: Int64?
    /// Unix seconds.
    var updatedAt: Int64?

    var isReceive: Bool {
        direction == "receive"
    }

    var isSend: Bool {
        direction == "send"
    }
}

extension ArkadeSwap {
    init(_ swap: BitkitCore.ArkadeSwap) {
        self.init(
            id: swap.id,
            direction: swap.direction,
            outcome: swap.outcome,
            takeSat: Int64(clamping: swap.takeSat),
            feeSat: Int64(clamping: swap.feeSat),
            bolt11: swap.bolt11,
            paymentHash: swap.paymentHash,
            createdAt: Int64(clamping: swap.createdAt),
            updatedAt: Int64(clamping: swap.updatedAt)
        )
    }
}

struct ArkadePayQuote {
    let feeSat: Int64
}

struct ArkadeLightningAddress {
    let lightningAddress: String?
    let lnurl: String
}
