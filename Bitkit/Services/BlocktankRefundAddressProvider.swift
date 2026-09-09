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
    static var key: String { key(for: Env.network) }

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

@MainActor
protocol BlocktankRefundAddressProviding: AnyObject {
    func addressForOrder() async throws -> String
}

@MainActor
final class BlocktankRefundAddressProvider: BlocktankRefundAddressProviding {
    static let maximumExternalIndex = UInt32(Int32.max)
    static let maximumAllocationAttempts = 20

    typealias Load = () throws -> BlocktankRefundAddress?
    typealias Save = (BlocktankRefundAddress) throws -> Void
    typealias Lookup = (UInt32) async throws -> BlocktankRefundAddress
    typealias Reveal = (UInt32) async throws -> Void
    typealias IsUsed = (String) async throws -> Bool
    typealias Allocate = () async throws -> BlocktankRefundAddress

    private let load: Load
    private let save: Save
    private let lookup: Lookup
    private let reveal: Reveal
    private let isUsed: IsUsed
    private let allocate: Allocate
    private var inFlight: Task<String, Error>?

    init(
        load: @escaping Load,
        save: @escaping Save,
        lookup: @escaping Lookup,
        reveal: @escaping Reveal,
        isUsed: @escaping IsUsed,
        allocate: @escaping Allocate
    ) {
        self.load = load
        self.save = save
        self.lookup = lookup
        self.reveal = reveal
        self.isUsed = isUsed
        self.allocate = allocate
    }

    convenience init(
        lightningService: LightningService,
        utilityService: UtilityService,
        store: BlocktankRefundAddressStore = .init()
    ) {
        self.init(
            load: { try store.load() },
            save: { try store.save($0) },
            lookup: { index in
                let info = try await lightningService.addressInfoForType(
                    .nativeSegwit,
                    keychain: .external,
                    atIndex: index
                )
                return BlocktankRefundAddress(address: info.address, index: info.index)
            },
            reveal: { index in
                try await lightningService.revealReceiveAddresses(to: index, forType: .nativeSegwit)
            },
            isUsed: { address in
                try await utilityService.isAddressUsed(address: address)
            },
            allocate: {
                let info = try await lightningService.newAddressInfoForType(.nativeSegwit)
                return BlocktankRefundAddress(address: info.address, index: info.index)
            }
        )
    }

    func addressForOrder() async throws -> String {
        if let inFlight {
            return try await inFlight.value
        }

        let operation = Task { @MainActor [load, save, lookup, reveal, isUsed, allocate] in
            try await Self.resolve(
                load: load,
                save: save,
                lookup: lookup,
                reveal: reveal,
                isUsed: isUsed,
                allocate: allocate
            )
        }
        inFlight = operation
        defer { inFlight = nil }
        return try await operation.value
    }

    private static func resolve(
        load: Load,
        save: Save,
        lookup: Lookup,
        reveal: Reveal,
        isUsed: IsUsed,
        allocate: Allocate
    ) async throws -> String {
        var previousIndex: UInt32?

        if let cached = try load() {
            try validate(cached)

            let derived = try await lookup(cached.index)
            guard derived == cached else {
                throw BlocktankRefundAddressError.ownershipMismatch
            }

            try await reveal(cached.index)
            if try await isUsed(cached.address) == false {
                return cached.address
            }
            previousIndex = cached.index
        }

        for _ in 0 ..< maximumAllocationAttempts {
            let generated = try await allocate()
            try validate(generated)
            if let previousIndex, generated.index <= previousIndex {
                throw BlocktankRefundAddressError.allocationDidNotAdvance
            }
            previousIndex = generated.index

            if try await isUsed(generated.address) {
                continue
            }

            try save(generated)
            return generated.address
        }

        throw BlocktankRefundAddressError.allocationAttemptsExhausted
    }

    private static func validate(_ value: BlocktankRefundAddress) throws {
        guard !value.address.isEmpty else {
            throw BlocktankRefundAddressError.invalidAddress
        }
        guard value.index <= maximumExternalIndex else {
            throw BlocktankRefundAddressError.indexOutOfRange(value.index)
        }
    }
}
