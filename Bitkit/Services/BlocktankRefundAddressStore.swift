import Foundation
import LDKNode

enum BlocktankRefundAddressError: LocalizedError, Equatable {
    case invalidCache
    case invalidAddress
    case indexOutOfRange(UInt32)
    case ownershipMismatch
    case persistenceFailed
    case allocationDidNotAdvance
    case allocationAttemptsExhausted

    var errorDescription: String? {
        switch self {
        case .invalidCache:
            "The saved Blocktank refund address is invalid."
        case .invalidAddress:
            "The Blocktank refund address is empty."
        case let .indexOutOfRange(index):
            "The Blocktank refund address index is out of range: \(index)."
        case .ownershipMismatch:
            "The saved Blocktank refund address does not belong to the active wallet and network."
        case .persistenceFailed:
            "The Blocktank refund address could not be saved."
        case .allocationDidNotAdvance:
            "The Blocktank refund address index did not advance."
        case .allocationAttemptsExhausted:
            "No unused Blocktank refund address was found."
        }
    }
}

struct BlocktankRefundAddressStore {
    static let legacyKey = "blocktankRefundAddress"
    static var key: String {
        key(for: Env.network)
    }

    private let defaults: UserDefaults
    private let network: LDKNode.Network

    private var key: String {
        Self.key(for: network)
    }

    init(defaults: UserDefaults = .standard, network: LDKNode.Network = Env.network) {
        self.defaults = defaults
        self.network = network
    }

    static func key(for network: LDKNode.Network) -> String {
        "\(legacyKey)_\(Env.networkName(for: network))"
    }

    func load() throws -> BlocktankRefundAddress? {
        if let value = try load(forKey: key) {
            return value
        }

        guard let legacy = try load(forKey: Self.legacyKey) else { return nil }
        let matchingNetworks = Self.matchingNetworks(for: legacy.address)
        guard !matchingNetworks.isEmpty else {
            throw BlocktankRefundAddressError.invalidCache
        }
        guard matchingNetworks == [network] else { return nil }

        try save(legacy)
        defaults.removeObject(forKey: Self.legacyKey)
        return legacy
    }

    private func load(forKey key: String) throws -> BlocktankRefundAddress? {
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let data = defaults.data(forKey: key) else {
            throw BlocktankRefundAddressError.invalidCache
        }

        do {
            return try JSONDecoder().decode(BlocktankRefundAddress.self, from: data)
        } catch {
            throw BlocktankRefundAddressError.invalidCache
        }
    }

    func save(_ value: BlocktankRefundAddress) throws {
        let data = try JSONEncoder().encode(value)
        let previousValue = defaults.object(forKey: key)
        defaults.set(data, forKey: key)

        do {
            guard try load(forKey: key) == value else {
                throw BlocktankRefundAddressError.persistenceFailed
            }
        } catch {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            throw BlocktankRefundAddressError.persistenceFailed
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)

        guard defaults.object(forKey: Self.legacyKey) != nil else { return }
        guard let legacy = try? load(forKey: Self.legacyKey) else {
            defaults.removeObject(forKey: Self.legacyKey)
            return
        }
        let matchingNetworks = Self.matchingNetworks(for: legacy.address)
        if matchingNetworks.isEmpty || matchingNetworks == [network] {
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    private static func matchingNetworks(for address: String) -> [LDKNode.Network] {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("bc1q") {
            return [.bitcoin]
        }
        if trimmed.hasPrefix("bcrt1q") {
            return [.regtest]
        }
        if trimmed.hasPrefix("tb1q") {
            return [.testnet, .signet]
        }
        return []
    }
}
