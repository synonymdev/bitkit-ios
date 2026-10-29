import Foundation

/// The Lightning node that serves this wallet: it opens a channel just in time for the first receive,
/// grows it by splicing, and is the wallet's only Lightning peer.
struct PrimaryNode: Hashable {
    static let uriKey = "primaryNodeUri"
    static let fundingPausedKey = "primaryFundingPaused"

    let nodeId: String
    let address: String?

    var uri: String {
        address.map { "\(nodeId)@\($0)" } ?? nodeId
    }

    var peer: LnPeer? {
        guard let address else { return nil }
        return try? LnPeer(connection: "\(nodeId)@\(address)")
    }

    /// Parses a `pubkey` or `pubkey@host:port` node URI, as pasted or scanned.
    static func parse(_ input: String) throws -> PrimaryNode {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["lightning://", "lightning:", "node://"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard (1 ... 2).contains(parts.count), !value.contains(where: \.isWhitespace) else {
            throw PrimaryNodeError.invalidInput
        }
        let nodeId = parts[0].lowercased()
        guard nodeId.range(of: "^(02|03)[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PrimaryNodeError.invalidInput
        }
        return try PrimaryNode(nodeId: nodeId, address: parts.count == 2 ? parseAddress(parts[1]) : nil)
    }

    static func parseOrNil(_ input: String) -> PrimaryNode? {
        try? parse(input)
    }

    /// The primary the wallet uses: the paired one, else the network's default.
    static func effective(savedUri: String?) -> PrimaryNode? {
        let saved = savedUri ?? ""
        return parseOrNil(saved.isEmpty ? Env.defaultPrimaryNodeUri : saved)
    }

    /// The primary saved in settings, else the network's default.
    static var current: PrimaryNode? {
        effective(savedUri: UserDefaults.standard.string(forKey: uriKey))
    }

    private static func parseAddress(_ value: String) throws -> String {
        guard let separator = value.lastIndex(of: ":") else { throw PrimaryNodeError.invalidInput }
        let host = String(value[..<separator]).lowercased()
        guard let port = UInt16(value[value.index(after: separator)...]), port > 0,
              host.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil
        else {
            throw PrimaryNodeError.invalidInput
        }
        return "\(host):\(port)"
    }
}

enum PrimaryNodeError: Error, Equatable {
    case invalidInput
    case addressUnknown
    case connectionInUse
    case notConfigured
}

/// Why the primary node could not provide a receive or a channel change, shown to the user.
enum PrimaryReceiveError: Error, Equatable {
    case insufficientFunds
    case rejected
    case timedOut
    case amountTooSmall
    case offline
    case busy
    case spliceFailed
}
