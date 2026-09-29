@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class PaykitContactLifecycleTests: XCTestCase {
    func testDeletionBlocksEveryKnownReceiverBeforeRemovingContact() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.removeContact(publicKey: sdk.publicKey)
        XCTAssertNil(sdk.record)
        XCTAssertEqual(sdk.events, ["block:bitkit/server", "block:bitkit/wallet", "remove"])
        XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
    }

    func testFailedBlockKeepsContactAvailableForDeletionRetry() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        sdk.failBlock = true
        let service = PaykitSdkService(sdkFactory: { sdk })
        do {
            _ = try await service.removeContact(publicKey: sdk.publicKey)
            XCTFail("Expected the failed block to prevent deletion")
        } catch {}
        XCTAssertNotNil(sdk.record)
        XCTAssertFalse(sdk.events.contains("remove"))
    }

    func testOnlyExplicitReaddRestoresAllPrivateConnections() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.removeContact(publicKey: sdk.publicKey)
        do {
            _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Updated")
            XCTFail("Background refresh must not recreate a deleted contact")
        } catch {}
        XCTAssertNil(sdk.record)
        XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .blocked })
        _ = try await service.saveContact(publicKey: sdk.publicKey, label: "Readded", restorePrivateConnection: true)
        XCTAssertTrue(sdk.peers.allSatisfy { $0.state == .notLinked })
        XCTAssertEqual(sdk.record?.label, "Readded")
    }

    func testBlockedPeerCleanupDoesNotAttemptNetworkDelivery() async throws {
        let sdk = ContactLifecycleSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.removeContact(publicKey: sdk.publicKey)
        let report = try await service.clearPrivatePaymentList(to: sdk.publicKey, receiverPath: PaykitReceiverPath.server)
        XCTAssertNil(report)
    }
}

private final class ContactLifecycleSdk: PaykitSdk, @unchecked Sendable {
    let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    var events: [String] = []
    var failBlock = false
    lazy var record: ContactRecord? = ContactRecord(
        publicKey: publicKey, receiverPaths: [PaykitReceiverPath.wallet], label: "Contact", profile: nil,
        profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
        publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
        publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
    )
    lazy var peers: [LinkedPeerRecord] = [PaykitReceiverPath.wallet, PaykitReceiverPath.server].map {
        LinkedPeerRecord(counterparty: publicKey, counterpartyReceiverPath: $0, state: .linked,
                         lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
                         localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
                         remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil)
    }

    override func backupStateRevision() async throws -> String {
        "revision"
    }

    override func contactRecord(publicKey: String) async throws -> ContactRecord? {
        record
    }

    override func linkedPeers() async throws -> [LinkedPeerRecord] {
        peers
    }

    override func blockPeer(counterparty: String, counterpartyReceiverPath: String) async throws -> LinkedPeerRecord {
        if failBlock { throw PubkyServiceError.profileNotFound }
        events.append("block:\(counterpartyReceiverPath)")
        let index = try XCTUnwrap(peers.firstIndex { $0.counterpartyReceiverPath == counterpartyReceiverPath })
        peers[index].state = .blocked
        return peers[index]
    }

    override func unblockPeer(counterparty: String, counterpartyReceiverPath: String) async throws -> LinkedPeerRecord {
        let index = try XCTUnwrap(peers.firstIndex { $0.counterpartyReceiverPath == counterpartyReceiverPath })
        peers[index].state = .notLinked
        return peers[index]
    }

    override func removeContact(publicKey: String) async throws -> ContactRecord? {
        events.append("remove")
        defer { record = nil }
        return record
    }

    override func saveContact(update: ContactUpdate) async throws -> ContactRecord {
        let saved = ContactRecord(
            publicKey: update.publicKey, receiverPaths: update.receiverPaths, label: update.label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-09-29T00:00:00Z", updatedAt: "2026-09-29T00:00:00Z",
            publicContactMarkerStatus: .notPublished, publicContactMarkerReceiverPath: nil,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
        record = saved
        return saved
    }
}
