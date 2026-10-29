import Foundation

/// Arkade's wallet and Lightning client for Bitkit. The engine is a Rust binding on `arkade-os/rust-sdk` (ark-rs) over
/// UniFFI, shared with Android, which adds the Arkade Intents Lightning client the Rust SDK lacks. Until it lands,
/// every call throws `ArkadeError.unsupported` and Arkade stays off, so every flow takes its channel path.
@MainActor
final class ArkadeBridge {
    var onEvent: ((ArkadeBridgeEvent) -> Void)?
    var onTerminated: (() -> Void)?

    static let isAvailable = false

    func start(_: ArkadeStartParams) async throws -> ArkadeInfo {
        throw ArkadeError.unsupported
    }

    func info() async throws -> ArkadeInfo {
        throw ArkadeError.unsupported
    }

    func balance() async throws -> ArkadeBalance {
        throw ArkadeError.unsupported
    }

    func vtxos() async throws -> [ArkadeVtxo] {
        throw ArkadeError.unsupported
    }

    func history() async throws -> [ArkadeHistoryEntry] {
        throw ArkadeError.unsupported
    }

    func swaps() async throws -> [ArkadeSwap] {
        throw ArkadeError.unsupported
    }

    func receive(amountSats _: UInt64) async throws -> ArkadeSwap {
        throw ArkadeError.unsupported
    }

    func quotePay(bolt11 _: String) async throws -> ArkadePayQuote {
        throw ArkadeError.unsupported
    }

    func pay(bolt11 _: String) async throws -> ArkadeSwap {
        throw ArkadeError.unsupported
    }

    func offboard(address _: String) async throws -> String {
        throw ArkadeError.unsupported
    }

    func lightningAddress() async throws -> ArkadeLightningAddress? {
        throw ArkadeError.unsupported
    }

    func exportState() async throws -> String {
        throw ArkadeError.unsupported
    }

    func wipe() async throws {}
    func reload() async throws {}
}

enum ArkadeBridgeEvent {
    case swap(ArkadeSwap)
    case history([ArkadeHistoryEntry])
}

/// What `start` gets; the mnemonic and passphrase leave the app only inside this call.
struct ArkadeStartParams: Encodable {
    let mnemonic: String
    let passphrase: String?
    let network: String
    let arkServerUrl: String
    let delegateUrl: String?
    let lnurlUrl: String?
    let restore: Bool
    let backup: String?
}

struct ArkadeInfo: Decodable {
    let arkAddress: String
    let boardingAddress: String
    let network: String
}

struct ArkadeBalance: Decodable {
    var available: Int64 = 0
    var recoverable: Int64 = 0
    var boardingConfirmed: Int64 = 0
    var boardingUnconfirmed: Int64 = 0

    init(available: Int64 = 0, recoverable: Int64 = 0, boardingConfirmed: Int64 = 0, boardingUnconfirmed: Int64 = 0) {
        self.available = available
        self.recoverable = recoverable
        self.boardingConfirmed = boardingConfirmed
        self.boardingUnconfirmed = boardingUnconfirmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Int64.self, forKey: .available) ?? 0
        recoverable = try container.decodeIfPresent(Int64.self, forKey: .recoverable) ?? 0
        boardingConfirmed = try container.decodeIfPresent(Int64.self, forKey: .boardingConfirmed) ?? 0
        boardingUnconfirmed = try container.decodeIfPresent(Int64.self, forKey: .boardingUnconfirmed) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case available, recoverable, boardingConfirmed, boardingUnconfirmed
    }
}

struct ArkadeVtxo: Decodable, Equatable {
    var txid: String?
    /// Unix seconds, or milliseconds, after which the operator may sweep this output unless it is renewed.
    var batchExpiry: Int64?
    var isSwept: Bool?

    init(txid: String? = nil, batchExpiry: Int64? = nil, isSwept: Bool? = nil) {
        self.txid = txid
        self.batchExpiry = batchExpiry
        self.isSwept = isSwept
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        txid = try? container.decodeIfPresent(String.self, forKey: .txid)
        batchExpiry = try? container.decodeIfPresent(Int64.self, forKey: .batchExpiry)
        isSwept = try? container.decodeIfPresent(Bool.self, forKey: .isSwept)
    }

    private enum CodingKeys: String, CodingKey {
        case txid, batchExpiry, isSwept
    }
}

struct ArkadeHistoryEntry: Decodable, Equatable {
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

/// A Lightning swap through Arkade Intents: `receive` pays into the wallet, `send` pays an invoice out of it.
struct ArkadeSwap: Decodable, Equatable {
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

    init(
        id: String? = nil,
        direction: String? = nil,
        outcome: String? = nil,
        takeSat: Int64? = nil,
        feeSat: Int64? = nil,
        bolt11: String? = nil,
        paymentHash: String? = nil,
        createdAt: Int64? = nil,
        updatedAt: Int64? = nil
    ) {
        self.id = id
        self.direction = direction
        self.outcome = outcome
        self.takeSat = takeSat
        self.feeSat = feeSat
        self.bolt11 = bolt11
        self.paymentHash = paymentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Reads each field on its own, so one the bridge reports in another shape doesn't drop the whole swap.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        direction = try? container.decodeIfPresent(String.self, forKey: .direction)
        outcome = try? container.decodeIfPresent(String.self, forKey: .outcome)
        takeSat = try? container.decodeIfPresent(Int64.self, forKey: .takeSat)
        feeSat = try? container.decodeIfPresent(Int64.self, forKey: .feeSat)
        bolt11 = try? container.decodeIfPresent(String.self, forKey: .bolt11)
        paymentHash = try? container.decodeIfPresent(String.self, forKey: .paymentHash)
        createdAt = try? container.decodeIfPresent(Int64.self, forKey: .createdAt)
        updatedAt = try? container.decodeIfPresent(Int64.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, direction, outcome, takeSat, feeSat, bolt11, paymentHash, createdAt, updatedAt
    }

    var isReceive: Bool {
        direction == "receive"
    }

    var isSend: Bool {
        direction == "send"
    }
}

struct ArkadePayQuote: Decodable {
    let feeSat: Int64
}

struct ArkadeLightningAddress: Decodable {
    let lightningAddress: String?
    let lnurl: String
}

private struct ArkadeTxid: Decodable {
    let txid: String?
}
