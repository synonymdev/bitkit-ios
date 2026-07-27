@testable import Bitkit
import Foundation
import Paykit
import XCTest

final class PaykitReceiverNoiseKeyStoreTests: XCTestCase {
    func testDerivationMatchesVersionedCrossPlatformVector() {
        let seed = "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
            .hexaData

        let key = PaykitReceiverNoiseKeyDerivation.derive(
            seed: seed,
            network: "bitcoin",
            receiverPath: "bitkit/wallet"
        )

        XCTAssertEqual(key.hex, "500f4799bbb2d02103e3b74b365ddb478a3187333c053fa9eb62f4052ba6a327")
    }

    func testDerivesPersistsAndReusesReceiverNoiseKey() throws {
        var persistedBytes: Data?
        let derivedBytes = Data(repeating: 7, count: 32)
        let store = PaykitReceiverNoiseKeyStore(
            loadBytes: { persistedBytes },
            upsertBytes: { persistedBytes = $0 },
            deriveBytes: { derivedBytes }
        )

        let first = try store.loadOrDerive().exportBytes()
        let second = try store.loadOrDerive().exportBytes()
        let restoredStore = PaykitReceiverNoiseKeyStore(
            loadBytes: { persistedBytes },
            upsertBytes: { persistedBytes = $0 },
            deriveBytes: { derivedBytes }
        )
        let restored = try restoredStore.loadOrDerive().exportBytes()

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
            upsertBytes: { persistedBytes = $0 },
            deriveBytes: { Data(repeating: 1, count: 32) }
        )

        XCTAssertThrowsError(try store.persist(ReceiverNoiseSecretKey(bytes: Data(repeating: 2, count: 32))))
        XCTAssertEqual(persistedBytes, Data(repeating: 1, count: 32))
    }

    func testRejectsInvalidPersistedReceiverNoiseKey() {
        let store = PaykitReceiverNoiseKeyStore(
            loadBytes: { Data(repeating: 0, count: 31) },
            upsertBytes: { _ in XCTFail("Invalid bytes must not be overwritten") },
            deriveBytes: { Data(repeating: 0, count: 32) }
        )

        XCTAssertThrowsError(try store.loadOrDerive())
    }

    func testRejectsCachedKeyFromAnotherWalletSeed() {
        let store = PaykitReceiverNoiseKeyStore(
            loadBytes: { Data(repeating: 1, count: 32) },
            upsertBytes: { _ in XCTFail("Mismatched bytes must not be overwritten") },
            deriveBytes: { Data(repeating: 2, count: 32) }
        )

        XCTAssertThrowsError(try store.loadOrDerive())
    }
}
