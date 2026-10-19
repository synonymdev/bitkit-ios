@testable import Bitkit
import XCTest

@MainActor
final class ShopContactImporterTests: XCTestCase {
    private let buyer = String(repeating: "y", count: 52)
    private let seller = String(repeating: "b", count: 51) + "y"
    private let other = String(repeating: "n", count: 51) + "y"

    func testPaginationImportsHistoricalMarkersAndSkipsHandledSellersOnRescan() async throws {
        let root = "pubky://\(buyer)\(ShopContactImporter.markerPath)"
        let first = "\(root)\(seller).json"
        let second = "\(root)\(other).json"
        var cursors: [String?] = []
        var reads: [String] = []
        var saves: [[String]] = []
        let importer = ShopContactImporter(listPage: { _, cursor, limit in
            XCTAssertEqual(limit, 10)
            cursors.append(cursor)
            switch cursor {
            case nil: return [first]
            case first: return [second]
            default: return []
            }
        }, fetchFile: { uri, _ in
            reads.append(uri)
            let key = uri.contains(self.seller) ? self.seller : self.other
            return self.file(uri: uri, seller: key)
        }, saveContacts: { keys, _, current in
            let valid = await current()
            XCTAssertTrue(valid)
            saves.append(keys)
            return !keys.isEmpty
        })
        for _ in 0 ..< 4 {
            _ = try await importer.importPage(publicKey: "pubky\(buyer)") { true }
        }
        XCTAssertEqual(cursors, [nil, first, second, nil])
        XCTAssertEqual(saves.filter { !$0.isEmpty }, [["pubky\(seller)"], ["pubky\(other)"]])
        XCTAssertEqual(reads.count, 4)
    }

    func testInvalidMarkersAreSkippedAndMissingStorefrontCanRetry() async throws {
        let root = "pubky://\(buyer)\(ShopContactImporter.markerPath)"
        let uri = "\(root)\(seller).json"
        var marker = "{}"
        var storefrontAvailable = false
        var storefront: String?
        var saves: [[String]] = []
        let importer = ShopContactImporter(listPage: { _, cursor, _ in
            cursor == nil ? ["\(root)\(self.buyer).json", "pubky://\(self.other)\(ShopContactImporter.markerPath)\(self.seller).json", uri] : []
        }, fetchFile: { path, _ in
            if path == uri { return Data(marker.utf8) }
            guard storefrontAvailable else { throw PubkyServiceError.profileNotFound }
            if let storefront { return Data(storefront.utf8) }
            return self.file(uri: path, seller: self.seller)
        }, saveContacts: { keys, _, _ in
            saves.append(keys)
            return !keys.isEmpty
        })
        for invalid in ["{}", "{\"seller\":\"\(other)\",\"completedAt\":1}", "{\"seller\":\"\(seller)\",\"completedAt\":0}"] {
            marker = invalid
            _ = try await importer.importPage(publicKey: buyer) { true }
            _ = try await importer.importPage(publicKey: buyer) { true }
        }
        marker = "{\"seller\":\"\(seller)\",\"completedAt\":1}"
        _ = try await importer.importPage(publicKey: buyer) { true }
        _ = try await importer.importPage(publicKey: buyer) { true }
        XCTAssertTrue(saves.allSatisfy(\.isEmpty))
        storefrontAvailable = true
        for invalid in [
            "{}",
            "{\"schemaVersion\":2,\"recordType\":\"shop\",\"ownerPubky\":\"\(seller)\"}",
            "{\"schemaVersion\":1,\"recordType\":\"listing\",\"ownerPubky\":\"\(seller)\"}",
            "{\"schemaVersion\":1,\"recordType\":\"shop\",\"ownerPubky\":\"\(other)\"}",
        ] {
            storefront = invalid
            let changed = try await importer.importPage(publicKey: buyer) { true }
            XCTAssertFalse(changed)
            _ = try await importer.importPage(publicKey: buyer) { true }
        }
        storefront = nil
        let changed = try await importer.importPage(publicKey: buyer) { true }
        XCTAssertTrue(changed)
        XCTAssertEqual(saves.last, ["pubky\(seller)"])
    }

    func testOverlappingPollsCoalesceAndResetDiscardsAReadInFlight() async throws {
        let started = expectation(description: "listing started")
        var release: CheckedContinuation<[String], Never>?
        var saves = 0
        let importer = ShopContactImporter(listPage: { _, _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }, fetchFile: { _, _ in XCTFail("A reset invalidates the page"); return Data() }, saveContacts: { _, _, _ in
            saves += 1
            return true
        })
        let pending = Task { try await importer.importPage(publicKey: buyer) { true } }
        await fulfillment(of: [started], timeout: 2)
        let overlap = try await importer.importPage(publicKey: buyer) { true }
        XCTAssertFalse(overlap)
        importer.reset()
        release?.resume(returning: ["pubky://\(buyer)\(ShopContactImporter.markerPath)\(seller).json"])
        do { _ = try await pending.value; XCTFail("Reset must invalidate the page") } catch PubkyServiceError.identityChanged {}
        XCTAssertEqual(saves, 0)
        let cancelled = Task { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.importPage(publicKey: buyer) { true }
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation must stop new reads") } catch is CancellationError {}
    }

    func testCommittedImportRefreshRetriesBeforeDiscoveryAfterInterruption() async throws {
        for interruptedSave in [false, true] {
            var discoveryAvailable = true
            var interrupted = false
            var writes = 0
            var refreshes = 0
            let importer = ShopContactImporter(listPage: { _, _, _ in
                guard discoveryAvailable else { throw PubkyServiceError.profileNotFound }
                return ["pubky://\(self.buyer)\(ShopContactImporter.markerPath)\(self.seller).json"]
            }, fetchFile: { uri, _ in self.file(uri: uri, seller: self.seller) }, saveContacts: { _, _, _ in
                writes += 1
                if interruptedSave, !interrupted {
                    interrupted = true
                    throw CancellationError()
                }
                return false
            })
            let refresh = {
                refreshes += 1
                if !interruptedSave, !interrupted {
                    interrupted = true
                    throw PubkyServiceError.profileNotFound
                }
            }
            do {
                _ = try await importer.importPage(publicKey: buyer, refreshContacts: refresh) { true }
                XCTFail("The interrupted attempt must fail")
            } catch is CancellationError {
                XCTAssertTrue(interruptedSave)
            } catch PubkyServiceError.profileNotFound {
                XCTAssertFalse(interruptedSave)
            }
            let before = refreshes
            discoveryAvailable = false
            do {
                _ = try await importer.importPage(publicKey: buyer, refreshContacts: refresh) { true }
                XCTFail("Discovery is offline")
            } catch PubkyServiceError.profileNotFound {}
            XCTAssertEqual(refreshes, before + 1)
            XCTAssertEqual(writes, 1)
            discoveryAvailable = true
            _ = try await importer.importPage(publicKey: buyer, refreshContacts: refresh) { true }
            XCTAssertEqual(refreshes, before + 2)
        }
    }

    private func file(uri: String, seller: String) -> Data {
        if uri.hasSuffix("shop.json") {
            return Data("{\"schemaVersion\":1,\"recordType\":\"shop\",\"ownerPubky\":\"\(seller)\"}".utf8)
        }
        return Data("{\"seller\":\"\(seller)\",\"completedAt\":1}".utf8)
    }
}
