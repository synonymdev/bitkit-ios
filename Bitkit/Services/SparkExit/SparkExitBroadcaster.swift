import BreezSdkSpark
import Foundation

struct EsploraTxStatus: Codable, Equatable {
    let confirmed: Bool
    var blockHeight: UInt32?

    enum CodingKeys: String, CodingKey {
        case confirmed
        case blockHeight = "block_height"
    }
}

struct EsploraUtxo: Codable, Equatable {
    let txid: String
    let vout: UInt32
    let value: UInt64
    let status: EsploraTxStatus
}

/// What a broadcast came to. Accepted includes a transaction the node already had.
enum SparkExitBroadcastOutcome: Equatable {
    case accepted
    /// Its relative timelock has not matured (`non-BIP68-final`): the next tick tries again. Never a rejection.
    case notMature(String)
    /// An input is missing or already spent: its parent is not visible yet, or another transaction spent it.
    case inputsMissing(String)
    /// The host or node could not take it now: the next tick tries again.
    case retryLater(String)
    /// Refused for good at this fee or policy; a later check or rebuild replaces it.
    case rejected(String)

    var summary: String {
        switch self {
        case .accepted: "accepted"
        case let .notMature(reason): "not mature: \(reason)"
        case let .inputsMissing(reason): "inputs missing: \(reason)"
        case let .retryLater(reason): "retry: \(reason)"
        case let .rejected(reason): "rejected: \(reason)"
        }
    }
}

/// The chain the Spark SDK reads, for what an exit does outside the SDK: broadcasting and the funding address.
protocol SparkExitChain: Sendable {
    func tipHeight() async throws -> UInt32
    func utxos(address: String) async throws -> [EsploraUtxo]
    func txStatus(txid: String) async throws -> EsploraTxStatus
    func broadcast(_ tx: RecoveryTransaction) async -> SparkExitBroadcastOutcome
}

protocol SparkExitHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionSparkExitHTTP: SparkExitHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// esplora and mempool.space REST, on the hosts the Spark SDK uses by default: a transaction with a CPFP child goes
/// out as a package through `/v1/txs/package` (JSON array of hex), one without as a single `/tx`.
struct EsploraSparkExitChain: SparkExitChain {
    let hosts: [URL]
    var http: SparkExitHTTP = URLSessionSparkExitHTTP()

    /// The Spark SDK's default chain service for each network (breez spark-sdk `default_rest_chain_services`).
    static func defaultHosts(for network: BreezSdkSpark.Network) -> [URL] {
        switch network {
        case .mainnet: [URL(string: "https://mempool.space/api")!, URL(string: "https://blockstream.info/api")!]
        case .regtest: [URL(string: "https://regtest-mempool.us-west-2.sparkinfra.net/api")!]
        default: []
        }
    }

    func tipHeight() async throws -> UInt32 {
        let data = try await get("/blocks/tip/height")
        guard let height = UInt32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.cannotParseResponse)
        }
        return height
    }

    func utxos(address: String) async throws -> [EsploraUtxo] {
        try await JSONDecoder().decode([EsploraUtxo].self, from: get("/address/\(address)/utxo"))
    }

    func txStatus(txid: String) async throws -> EsploraTxStatus {
        try await JSONDecoder().decode(EsploraTxStatus.self, from: get("/tx/\(txid)/status"))
    }

    /// Tries each host until one accepts. Otherwise a node's refusal wins over a host that was only unavailable.
    func broadcast(_ tx: RecoveryTransaction) async -> SparkExitBroadcastOutcome {
        var outcomes: [SparkExitBroadcastOutcome] = []
        for host in hosts {
            let attempt: SparkExitBroadcastOutcome? = if let child = tx.cpfpTxHex {
                await submitPackage(host: host, hexes: [tx.txHex, child], txid: tx.txid)
            } else {
                await submitSingle(host: host, hex: tx.txHex)
            }
            // nil: this host cannot take it (no package endpoint, unreachable).
            guard let attempt else { continue }
            if attempt == .accepted {
                return attempt
            }
            outcomes.append(attempt)
        }
        return outcomes.first {
            if case .rejected = $0 {
                true
            } else {
                false
            }
        } ?? outcomes.first ?? .retryLater("no chain host reachable")
    }

    private func submitPackage(host: URL, hexes: [String], txid: String) async -> SparkExitBroadcastOutcome? {
        for path in ["/v1/txs/package", "/txs/package"] {
            var request = URLRequest(url: host.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(hexes)
            request.timeoutInterval = 30
            guard let (data, response) = try? await http.send(request) else { return nil }
            if response.statusCode == 404 || response.statusCode == 405 {
                continue
            }
            return SparkExitBroadcastClassifier.package(status: response.statusCode, body: data, txid: txid)
        }
        return nil
    }

    private func submitSingle(host: URL, hex: String) async -> SparkExitBroadcastOutcome? {
        var request = URLRequest(url: host.appendingPathComponent("/tx"))
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(hex.utf8)
        request.timeoutInterval = 30
        guard let (data, response) = try? await http.send(request) else { return nil }
        if response.statusCode == 404 || response.statusCode == 405 {
            return nil
        }
        return SparkExitBroadcastClassifier.single(status: response.statusCode, body: data)
    }

    private func get(_ path: String) async throws -> Data {
        var lastError: Error = URLError(.cannotFindHost)
        for host in hosts {
            var request = URLRequest(url: host.appendingPathComponent(path))
            request.timeoutInterval = 20
            do {
                let (data, response) = try await http.send(request)
                guard (200 ..< 300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// Reads node responses: mempool returns the RPC code only (`sendrawtransaction RPC error: {"code":-25}`),
/// esplora the message too, and a package the per-transaction errors.
enum SparkExitBroadcastClassifier {
    private static let knownMessages = [
        "txn-already-in-mempool",
        "txn-already-known",
        "txn-same-nonwitness-data-in-mempool",
        "already in block chain",
    ]
    private static let notMatureMessages = ["non-BIP68-final", "non-final"]
    private static let missingInputMessages = ["bad-txns-inputs-missingorspent", "missing-inputs", "missingorspent"]

    static func single(status: Int, body: Data) -> SparkExitBroadcastOutcome {
        let text = String(decoding: body, as: UTF8.self)
        if (200 ..< 300).contains(status) {
            return .accepted
        }
        if let unavailable = unavailable(status) {
            return unavailable
        }
        return classify(error: text)
    }

    /// `txid` is the package's parent, the step itself: an error on it decides the outcome. Missing inputs count as
    /// such only when the step reports them; the CPFP child's own missing input (its funding or chained change) is
    /// retried.
    static func package(status: Int, body: Data, txid: String? = nil) -> SparkExitBroadcastOutcome {
        let text = String(decoding: body, as: UTF8.self)
        if let unavailable = unavailable(status) {
            return unavailable
        }
        guard (200 ..< 300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return classify(error: text)
        }
        if json["package_msg"] as? String == "success" {
            return .accepted
        }
        let results = (json["tx-results"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let errors = results.compactMap { result in (result["error"] as? String).map { (txid: result["txid"] as? String, error: $0) } }
        if errors.isEmpty {
            return results.isEmpty ? .retryLater(text) : .accepted
        }
        // The step's own error decides, whatever its child reports and in whatever order the results come.
        if let txid, let own = errors.first(where: { $0.txid == txid }) {
            let outcome = classify(error: own.error)
            if outcome != .accepted {
                return outcome
            }
        }
        let outcomes = errors.map { result in
            let outcome = classify(error: result.error)
            if case .inputsMissing = outcome, let txid, let resultTxid = result.txid, resultTxid != txid {
                return SparkExitBroadcastOutcome.retryLater(result.error)
            }
            return outcome
        }
        if outcomes.allSatisfy({ $0 == .accepted }) {
            return .accepted
        }
        // A child of a parent not mature yet can fail with any error, so the timelock wins over them all.
        let precedence: (SparkExitBroadcastOutcome) -> Int = {
            switch $0 {
            case .notMature: 0
            case .rejected: 1
            case .inputsMissing: 2
            case .retryLater: 3
            case .accepted: 4
            }
        }
        return outcomes.min { precedence($0) < precedence($1) } ?? .accepted
    }

    /// A host that is down, rate limiting or behind a challenge page says nothing about the transaction.
    private static func unavailable(_ status: Int) -> SparkExitBroadcastOutcome? {
        status >= 500 || status == 429 || status == 403 ? .retryLater("HTTP \(status)") : nil
    }

    static func classify(error text: String) -> SparkExitBroadcastOutcome {
        if knownMessages.contains(where: text.contains) || hasRpcCode(-27, in: text) {
            return .accepted
        }
        if notMatureMessages.contains(where: text.contains) {
            return .notMature(text)
        }
        if missingInputMessages.contains(where: text.contains) || hasRpcCode(-25, in: text) {
            return .inputsMissing(text)
        }
        return .rejected(text)
    }

    /// The RPC code, also when the node's error sits JSON-escaped inside mempool's own error object.
    private static func hasRpcCode(_ code: Int, in text: String) -> Bool {
        text.range(of: #"code\\?"\s*:\s*\#(code)\b"#, options: .regularExpression) != nil
    }
}
