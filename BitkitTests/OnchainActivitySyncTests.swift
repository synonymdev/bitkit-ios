@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class OnchainActivitySyncTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("OnchainActivitySyncTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        snapshotAppDefaults("activityDetachedContacts", "onchainAddress")
        _ = Bitkit.CoreService.shared
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        _ = try initDb(basePath: database.path)
    }

    override func tearDown() async throws {
        await drainCoreServiceQueue()
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(at: database)
        try await super.tearDown()
    }

    func testAddressUsageIncludesEveryStoredBatchOutputAcrossWallets() async throws {
        let utility = Bitkit.CoreService.shared.utility
        for (index, walletId) in [WalletScope.default, "trezor:wallet"].enumerated() {
            let txid = String(repeating: String(index + 1), count: 64)
            let receiveAddress = "bcrt1qordinary\(index)"
            let publicAddress = "bcrt1qpublic\(index)"
            let unrelatedAddress = "bcrt1qunrelated\(index)"
            let timestamp: UInt64 = 1000
            try await Bitkit.CoreService.shared.activity.insert(.onchain(OnchainActivity(
                walletId: walletId, id: txid, txType: .received, txId: txid, value: 5000,
                fee: 0, feeRate: 1, address: receiveAddress, confirmed: true, timestamp: timestamp,
                isBoosted: false, boostTxIds: [], isTransfer: false, doesExist: true, confirmTimestamp: timestamp,
                channelId: nil, transferTxId: nil, contact: nil, createdAt: timestamp, updatedAt: timestamp, seenAt: nil
            )))
            let activityAddressUsed = try await utility.isAddressUsed(address: receiveAddress)
            let publicAddressUsedBeforeDetails = try await utility.isAddressUsed(address: publicAddress)
            XCTAssertTrue(activityAddressUsed)
            XCTAssertFalse(publicAddressUsedBeforeDetails)

            let details = BitkitCore.TransactionDetails(
                walletId: walletId, txId: txid, amountSats: 5000, inputs: [],
                outputs: [
                    TxOutput(scriptpubkey: "", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: receiveAddress, value: 3000, n: 0),
                    TxOutput(scriptpubkey: "", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: publicAddress, value: 2000, n: 1),
                ]
            )
            try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [details]) }

            let selectedAsActivityAddress = try await Bitkit.ServiceQueue.background(.core) {
                try BitkitCore.isAddressUsed(address: publicAddress)
            }
            let publicAddressUsed = try await utility.isAddressUsed(address: publicAddress)
            let unrelatedAddressUsed = try await utility.isAddressUsed(address: unrelatedAddress)
            XCTAssertFalse(selectedAsActivityAddress)
            XCTAssertTrue(publicAddressUsed)
            XCTAssertFalse(unrelatedAddressUsed)
        }
    }

    func testSyncPreservesContactRemovalDuringLookup() async throws {
        let txid = String(repeating: "12", count: 32)
        let address = "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"
        let contact = "pubky" + String(repeating: "y", count: 52)
        let lookupStarted = expectation(description: "Contact lookup started")
        let gate = LookupGate()
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
        activity.setPrivatePaykitContactResolvers(invoice: nil, onchainAddresses: { _, _ in
            lookupStarted.fulfill()
            await gate.wait()
            return contact
        })
        UserDefaults.standard.set(address, forKey: "onchainAddress")
        let timestamp = UInt64(Date().timeIntervalSince1970) + 10
        try await activity.insert(.onchain(OnchainActivity(
            walletId: WalletScope.default, id: txid, txType: .received, txId: txid, value: 5000,
            fee: 0, feeRate: 1, address: address, confirmed: false, timestamp: timestamp,
            isBoosted: false, boostTxIds: [], isTransfer: false, doesExist: true, confirmTimestamp: nil,
            channelId: nil, transferTxId: nil, contact: nil, createdAt: timestamp, updatedAt: timestamp, seenAt: nil
        )))
        let details = BitkitCore.TransactionDetails(
            walletId: WalletScope.default, txId: txid, amountSats: 5000, inputs: [],
            outputs: [TxOutput(scriptpubkey: "", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: address, value: 5000, n: 0)]
        )
        try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [details]) }
        let payment = LDKNode.PaymentDetails(
            id: String(repeating: "34", count: 32), kind: .onchain(txid: txid, status: .unconfirmed),
            amountMsat: 5_000_000, feePaidMsat: 0, direction: .inbound, status: .succeeded,
            latestUpdateTimestamp: timestamp
        )
        let syncing = Task { try await activity.syncLdkNodePayments([payment]) }
        await fulfillment(of: [lookupStarted], timeout: 5)
        do {
            try await activity.setContact(contact, forActivity: txid)
            try await activity.setContact(nil, forActivity: txid)
        } catch {
            await gate.release()
            _ = try? await syncing.value
            throw error
        }
        await gate.release()
        try await syncing.value

        let rows = try await activity.get(filter: .onchain, walletId: WalletScope.default)
        XCTAssertEqual(rows.count, 1)
        guard case let .onchain(row) = try XCTUnwrap(rows.first) else { return XCTFail("Expected onchain activity") }
        XCTAssertEqual(row.id, txid)
        XCTAssertEqual(row.txId, txid)
        XCTAssertNil(row.contact)
        XCTAssertTrue(activity.isContactDetached(activityId: txid, walletId: WalletScope.default))
    }

    func testSyncOverlappingSendKeepsOneAttributedActivityThroughConfirmation() async throws {
        let txid = String(repeating: "ab", count: 32)
        let contact = "pubky" + String(repeating: "y", count: 52)
        let lookupStarted = expectation(description: "Channel lookup started")
        let gate = LookupGate()
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in
            if await gate.shouldWait() {
                lookupStarted.fulfill()
                await gate.wait()
            }
            return nil
        })
        let timestamp = UInt64(Date().timeIntervalSince1970) + 10
        var payment = LDKNode.PaymentDetails(
            id: String(repeating: "cd", count: 32),
            kind: .onchain(txid: txid, status: .unconfirmed),
            amountMsat: 5_000_000,
            feePaidMsat: 209_000,
            direction: .outbound,
            status: .succeeded,
            latestUpdateTimestamp: timestamp
        )
        let syncing = Task { try await activity.syncLdkNodePayments([payment]) }
        await fulfillment(of: [lookupStarted], timeout: 5)
        let created = await activity.createSentOnchainActivityFromSendResult(
            txid: txid, address: "bcrt1qrecipient", amount: 5000, fee: 209,
            feeRate: 2, contact: contact
        )
        XCTAssertTrue(created)
        await gate.release()
        try await syncing.value

        for confirmed in [false, true] {
            if confirmed {
                payment.kind = .onchain(
                    txid: txid,
                    status: .confirmed(blockHash: String(repeating: "ef", count: 32), height: 100, timestamp: timestamp)
                )
                payment.latestUpdateTimestamp = timestamp + 1
                try await activity.syncLdkNodePayments([payment])
            }
            let rows = try await activity.get(filter: .onchain, walletId: WalletScope.default)
            XCTAssertEqual(rows.count, 1)
            guard case let .onchain(row) = try XCTUnwrap(rows.first) else { return XCTFail("Expected onchain activity") }
            XCTAssertEqual(row.id, txid)
            XCTAssertEqual(row.txId, txid)
            XCTAssertEqual(row.contact, contact)
            XCTAssertEqual(row.value, 5000)
            XCTAssertEqual(row.fee, 209)
            XCTAssertEqual(row.feeRate, 2)
            XCTAssertEqual(row.address, "bcrt1qrecipient")
            XCTAssertEqual(row.confirmed, confirmed)
        }
    }
}

private actor LookupGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func shouldWait() -> Bool {
        defer { started = true }
        return !started
    }

    func wait() async {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
