@testable import Bitkit
import Foundation
import Paykit
import XCTest

final class PaykitReceiverNoiseKeyStoreTests: XCTestCase {
    func testGeneratesPersistsAndReusesReceiverNoiseKey() throws {
        var persistedBytes: Data?
        let store = PaykitReceiverNoiseKeyStore(
            loadBytes: { persistedBytes },
            upsertBytes: { persistedBytes = $0 }
        )

        let first = try store.loadOrCreate().exportBytes()
        let second = try store.loadOrCreate().exportBytes()
        let restoredStore = PaykitReceiverNoiseKeyStore(
            loadBytes: { persistedBytes },
            upsertBytes: { persistedBytes = $0 }
        )
        let restored = try restoredStore.loadOrCreate().exportBytes()

        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(persistedBytes, first)
        XCTAssertEqual(second, first)
        XCTAssertEqual(restored, first)
        XCTAssertEqual(KeychainEntryType.paykitReceiverNoiseSecretKey.storageKey, "paykit_receiver_noise_secret_key")
    }

    func testRejectsUnexpectedReceiverNoiseKeyReplacement() throws {
        var persistedBytes: Data? = Data(repeating: 1, count: 32)
        let store = PaykitReceiverNoiseKeyStore(
            loadBytes: { persistedBytes },
            upsertBytes: { persistedBytes = $0 }
        )

        XCTAssertThrowsError(try store.persist(ReceiverNoiseSecretKey(bytes: Data(repeating: 2, count: 32))))
        XCTAssertEqual(persistedBytes, Data(repeating: 1, count: 32))
    }

    func testRejectsInvalidPersistedReceiverNoiseKey() {
        let store = PaykitReceiverNoiseKeyStore(
            loadBytes: { Data(repeating: 0, count: 31) },
            upsertBytes: { _ in XCTFail("Invalid bytes must not be overwritten") }
        )

        XCTAssertThrowsError(try store.loadOrCreate())
    }
}
