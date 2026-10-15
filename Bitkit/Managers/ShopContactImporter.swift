import Foundation

@MainActor
final class ShopContactImporter {
    static let markerPath = "/pub/pubky.app/migrations/seller-auto-follow/v1/"
    static let shopPath = "/pub/pubky.app/marketplace/v1/shop.json"
    static let pageSize: UInt16 = 10

    private let listPage: (String, String?, UInt16) async throws -> [String]
    private let fetchFile: (String, UInt64) async throws -> Data
    private let saveContacts: ([String], String, @escaping @Sendable () async -> Bool) async throws -> Bool
    private var owner: String?
    private var cursor: String?
    private var handled: Set<String> = []
    private var refreshPending = false
    private var isRunning = false
    private var generation = UUID()

    init(
        listPage: @escaping (String, String?, UInt16) async throws -> [String] = PubkyService.listPublicDirectoryPage,
        fetchFile: @escaping (String, UInt64) async throws -> Data = PubkyService.fetchPublicFile,
        saveContacts: @escaping ([String], String, @escaping @Sendable () async -> Bool) async throws -> Bool = PubkyService.importShopContacts
    ) {
        self.listPage = listPage
        self.fetchFile = fetchFile
        self.saveContacts = saveContacts
    }

    func reset() {
        owner = nil
        cursor = nil
        handled = []
        refreshPending = false
        generation = UUID()
    }

    func importPage(
        publicKey: String,
        refreshContacts: () async throws -> Void = {},
        isStillCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        if owner != publicKey {
            reset()
            owner = publicKey
        }
        let generation = generation
        let isCurrent: @MainActor @Sendable () -> Bool = { self.generation == generation && isStillCurrent() }
        try requireCurrent(isCurrent)
        if refreshPending {
            try await refreshContacts()
            try requireCurrent(isCurrent)
            refreshPending = false
        }
        guard let normalized = PubkyPublicKeyFormat.normalized(publicKey) else { throw PubkyServiceError.identityChanged }
        let buyer = String(normalized.dropFirst(5))
        let root = "pubky://\(buyer)\(Self.markerPath)"
        let page = try await listPage(root, cursor, Self.pageSize)
        try requireCurrent(isCurrent)
        var sellers: [String] = []
        for uri in page {
            try requireCurrent(isCurrent)
            guard uri.hasPrefix(root), uri.hasSuffix(".json") else { continue }
            let seller = String(uri.dropFirst(root.count).dropLast(5))
            guard seller.count == 52, PubkyPublicKeyFormat.normalized(seller) == "pubky\(seller)",
                  seller != buyer, !handled.contains(seller), !sellers.contains(seller)
            else { continue }
            do {
                let marker = try await JSONDecoder().decode(SellerMarker.self, from: fetchFile(uri, 4096))
                try requireCurrent(isCurrent)
                guard marker.seller == seller, marker.completedAt > 0 else { continue }
                let shop = try await JSONDecoder().decode(Storefront.self, from: fetchFile("pubky://\(seller)\(Self.shopPath)", 65536))
                // A storefront identifies a seller, not the app that wrote the buyer's marker.
                if shop.schemaVersion == 1, shop.recordType == "shop", shop.ownerPubky == seller {
                    sellers.append(seller)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        try requireCurrent(isCurrent)
        // A cancelled write may have committed; refresh before further discovery on retry.
        refreshPending = !sellers.isEmpty
        let changed = try await saveContacts(sellers.map { "pubky\($0)" }, publicKey, { await isCurrent() })
        try requireCurrent(isCurrent)
        if refreshPending {
            try await refreshContacts()
            try requireCurrent(isCurrent)
            refreshPending = false
        }
        handled.formUnion(sellers)
        cursor = page.last
        return changed
    }

    private func requireCurrent(_ isStillCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isStillCurrent() else { throw PubkyServiceError.identityChanged }
    }
}

private struct SellerMarker: Decodable {
    let seller: String
    let completedAt: Int64
}

private struct Storefront: Decodable {
    let schemaVersion: Int
    let recordType: String
    let ownerPubky: String
}
