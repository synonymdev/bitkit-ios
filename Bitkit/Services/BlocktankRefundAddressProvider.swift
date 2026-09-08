import Foundation
import LDKNode

enum BlocktankRefundAddressError: LocalizedError, Equatable {
    case invalidCache
    case invalidAddress
    case indexOutOfRange(UInt32)
    case ownershipMismatch
    case persistenceFailed

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
        }
    }
}

struct BlocktankRefundAddressStore {
    static let key = "blocktankRefundAddress"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> BlocktankRefundAddress? {
        guard defaults.object(forKey: Self.key) != nil else { return nil }
        guard let data = defaults.data(forKey: Self.key) else {
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
        defaults.set(data, forKey: Self.key)

        guard try load() == value else {
            throw BlocktankRefundAddressError.persistenceFailed
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

@MainActor
protocol BlocktankRefundAddressProviding: AnyObject {
    func addressForOrder() async throws -> String
}

@MainActor
final class BlocktankRefundAddressProvider: BlocktankRefundAddressProviding {
    static let maximumExternalIndex = UInt32(Int32.max)

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
        }

        let generated = try await allocate()
        try validate(generated)
        try save(generated)
        return generated.address
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
