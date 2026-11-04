@testable import Bitkit
import XCTest

final class HwRetainedSendServiceTests: XCTestCase {
    private let wallet = "jade:wallet"
    private let otherWallet = "trezor:wallet"
    private let segwitTx =
        "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try Keychain.delete(key: .hwRetainedSends)
    }

    override func tearDownWithError() throws {
        try Keychain.delete(key: .hwRetainedSends)
        try super.tearDownWithError()
    }

    private func send(walletId: String? = nil, serializedTx: String = "aabb") -> HwRetainedSend {
        HwRetainedSend(
            walletId: walletId ?? wallet,
            address: "bcrt1qaddress",
            sats: 42000,
            satsPerVByte: 2,
            serializedTx: serializedTx,
            miningFeeSats: 141,
            feeRate: 2.5,
            totalSpent: 42141
        )
    }

    private func assertThrows(_ action: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await action()
            XCTFail("Expected an error", file: file, line: line)
        } catch {}
    }

    func testRecordRoundTripsThroughKeychainStoreAcrossInstances() async throws {
        let original = send()
        try await HwRetainedSendService().retain(original)

        let reloaded = try await HwRetainedSendService().record(walletId: wallet)

        XCTAssertEqual(reloaded, original)
        XCTAssertEqual(reloaded?.retryWasRefused, false)
    }

    func testEachWalletHoldsItsOwnRecord() async throws {
        let service = HwRetainedSendService(store: MemoryRetainedSendStore())
        try await service.retain(send(serializedTx: "aa"))
        try await service.retain(send(walletId: otherWallet, serializedTx: "bb"))

        let first = try await service.record(walletId: wallet)
        let second = try await service.record(walletId: otherWallet)
        XCTAssertEqual(first?.serializedTx, "aa")
        XCTAssertEqual(second?.serializedTx, "bb")

        try await service.release(walletId: wallet)

        let released = try await service.record(walletId: wallet)
        let kept = try await service.record(walletId: otherWallet)
        XCTAssertNil(released)
        XCTAssertEqual(kept?.serializedTx, "bb")
    }

    func testRetainingDifferentBytesThrowsAndKeepsOriginal() async throws {
        let service = HwRetainedSendService(store: MemoryRetainedSendStore())
        try await service.retain(send(serializedTx: "aa"))

        await assertThrows { try await service.retain(self.send(serializedTx: "bb")) }

        let record = try await service.record(walletId: wallet)
        XCTAssertEqual(record?.serializedTx, "aa")
    }

    func testRetainingIdenticalBytesKeepsRefusedFlag() async throws {
        let service = HwRetainedSendService(store: MemoryRetainedSendStore())
        try await service.retain(send())
        try await service.markRetryRefused(walletId: wallet)

        try await service.retain(send())

        let record = try await service.record(walletId: wallet)
        XCTAssertEqual(record?.retryWasRefused, true)
    }

    func testMarkRetryRefusedOnlyAffectsThatWalletAndCreatesNoRecord() async throws {
        let service = HwRetainedSendService(store: MemoryRetainedSendStore())
        try await service.retain(send())

        try await service.markRetryRefused(walletId: otherWallet)

        let untouched = try await service.record(walletId: wallet)
        let missing = try await service.record(walletId: otherWallet)
        XCTAssertEqual(untouched?.retryWasRefused, false)
        XCTAssertNil(missing)
    }

    func testFailedWriteThrowsSoTheSendCanAbort() async {
        let store = MemoryRetainedSendStore()
        store.failSave = true
        let service = HwRetainedSendService(store: store)

        await assertThrows { try await service.retain(self.send()) }
    }

    func testObservedTxidReleasesCaseInsensitively() async throws {
        let service = HwRetainedSendService(store: MemoryRetainedSendStore())
        try await service.retain(send(serializedTx: segwitTx))
        let txid = try SignedTransactionId.fromHex(segwitTx)

        let unrelated = try await service.releaseIfObserved(walletId: wallet, txIds: [String(repeating: "0", count: 64)])
        let otherWalletReleased = try await service.releaseIfObserved(walletId: otherWallet, txIds: [txid])
        let stillHeld = try await service.record(walletId: wallet)
        XCTAssertFalse(unrelated)
        XCTAssertFalse(otherWalletReleased)
        XCTAssertNotNil(stillHeld)

        let released = try await service.releaseIfObserved(walletId: wallet, txIds: [txid.uppercased()])
        let record = try await service.record(walletId: wallet)
        XCTAssertTrue(released)
        XCTAssertNil(record)
    }

    func testInvalidHexNeverMatchesAnObservedTxid() async throws {
        let service = HwRetainedSendService(store: MemoryRetainedSendStore())
        let invalid = "not hex"
        try await service.retain(send(serializedTx: invalid))

        let released = try await service.releaseIfObserved(walletId: wallet, txIds: [invalid, ""])

        let record = try await service.record(walletId: wallet)
        XCTAssertFalse(released)
        XCTAssertEqual(record?.serializedTx, invalid)
    }

    func testCorruptDataThrowsAndIsNotOverwritten() async throws {
        let corrupt = Data("not json".utf8)
        try Keychain.upsert(key: .hwRetainedSends, data: corrupt)
        let service = HwRetainedSendService()

        await assertThrows { try await service.record(walletId: self.wallet) }
        await assertThrows { try await service.retain(self.send()) }
        await assertThrows { try await service.markRetryRefused(walletId: self.wallet) }
        await assertThrows { try await service.release(walletId: self.wallet) }
        await assertThrows { try await service.releaseIfObserved(walletId: self.wallet, txIds: []) }

        XCTAssertEqual(try Keychain.load(key: .hwRetainedSends), corrupt)
    }

    func testCorruptDataThrowsTheTypedError() async throws {
        try Keychain.upsert(key: .hwRetainedSends, data: Data("not json".utf8))

        do {
            _ = try await HwRetainedSendService().record(walletId: wallet)
            XCTFail("Expected an error")
        } catch {
            guard case HwRetainedSendError.corruptStore = error else { return XCTFail("\(error)") }
        }
    }

    func testAbandonDeletesACorruptEntryAndTheNextRetainSucceeds() async throws {
        try Keychain.upsert(key: .hwRetainedSends, data: Data("not json".utf8))
        let service = HwRetainedSendService()

        try await service.abandon(walletId: wallet)

        XCTAssertNil(try Keychain.load(key: .hwRetainedSends))
        try await service.retain(send())
        let record = try await service.record(walletId: wallet)
        XCTAssertEqual(record, send())
    }

    func testAbandonOfAReadableStoreOnlyReleasesThatWallet() async throws {
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        try await service.retain(send())
        try await service.retain(send(walletId: otherWallet))

        try await service.abandon(walletId: wallet)

        let released = try await service.record(walletId: wallet)
        let kept = try await service.record(walletId: otherWallet)
        XCTAssertNil(released)
        XCTAssertNotNil(kept)
        XCTAssertEqual(store.deleteEntryCalls, 0)
    }

    func testAbandonAfterAReadFailureThrowsAndDeletesNothing() async throws {
        let store = MockHwRetainedSendStore()
        let service = HwRetainedSendService(store: store)
        try await service.retain(send())
        store.setFailures(load: true)

        await assertThrows { try await service.abandon(walletId: self.wallet) }

        store.setFailures()
        XCTAssertEqual(store.deleteEntryCalls, 0)
        let record = try await service.record(walletId: wallet)
        XCTAssertEqual(record, send())
    }

    func testFullKeychainWipeClearsRecords() async throws {
        try await HwRetainedSendService().retain(send())

        try Keychain.wipeEntireKeychain()

        XCTAssertNil(try Keychain.load(key: .hwRetainedSends))
    }
}

private final class MemoryRetainedSendStore: HwRetainedSendStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var sends: [String: HwRetainedSend] = [:]
    var failSave = false

    func load() -> [String: HwRetainedSend] {
        lock.withLock { sends }
    }

    func save(_ sends: [String: HwRetainedSend]) throws {
        try lock.withLock {
            if failSave {
                throw MemoryRetainedSendStoreError.failed
            }
            self.sends = sends
        }
    }

    func deleteEntry() {
        lock.withLock { sends = [:] }
    }
}

private enum MemoryRetainedSendStoreError: Error {
    case failed
}
