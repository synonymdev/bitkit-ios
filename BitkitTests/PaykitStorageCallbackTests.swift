@testable import Bitkit
import Paykit
import XCTest

final class PaykitStorageCallbackTests: XCTestCase {
    private final class Storage: @unchecked Sendable {
        var data: Data?
        var failLoad = false
        var failSave = false

        func load() throws -> Data? {
            if failLoad {
                throw KeychainError.failedToLoad
            }
            return data
        }

        func save(_ data: Data) throws {
            if failSave {
                throw KeychainError.failedToSave
            }
            self.data = data
        }
    }

    private final class NoSession: SdkPubkySessionProvider, @unchecked Sendable {
        func loadSessionAccess() throws -> PubkySessionAccess? {
            nil
        }

        func publicStorageAvailable() throws -> Bool {
            false
        }

        func clearSessionAccess() throws {}
    }

    private final class SessionStorage: @unchecked Sendable {
        var failLoad = false
        var failDelete = false
        var deletedKeys: [Bitkit.KeychainEntryType] = []

        func loadSessionSecret() throws -> String? {
            if failLoad {
                throw KeychainError.failedToLoad
            }
            return nil
        }

        func deleteKeychainValue(_ key: Bitkit.KeychainEntryType) throws {
            if failDelete {
                throw KeychainError.failedToDelete
            }
            deletedKeys.append(key)
        }
    }

    func testNativeSdkCanRetryAfterProductionSessionLoadFailure() async throws {
        let storage = Storage()
        let sessionStorage = SessionStorage()
        let provider = PaykitSdkSessionProvider(
            loadSessionSecret: sessionStorage.loadSessionSecret,
            deleteKeychainValue: sessionStorage.deleteKeychainValue
        )
        let sdk = try PaykitSdk(
            stateStore: PaykitSdkStateBlobStore(loadData: storage.load, saveData: storage.save),
            sessionProvider: provider,
            config: Paykit.defaultConfig(receiverPath: PaykitReceiverPath.wallet)
        )

        sessionStorage.failLoad = true
        do {
            _ = try await sdk.identityStatus()
            XCTFail("Expected injected session load failure")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "session_load_failed")
        }

        sessionStorage.failLoad = false
        let identity = try await sdk.identityStatus()
        XCTAssertNil(identity)
        _ = try await sdk.forgetSessionAccess()
        XCTAssertNotNil(storage.data)
    }

    func testNativeSdkCanRetryAfterProductionSessionClearFailure() async throws {
        let storage = Storage()
        let sessionStorage = SessionStorage()
        let provider = PaykitSdkSessionProvider(
            loadSessionSecret: sessionStorage.loadSessionSecret,
            deleteKeychainValue: sessionStorage.deleteKeychainValue
        )
        let sdk = try PaykitSdk(
            stateStore: PaykitSdkStateBlobStore(loadData: storage.load, saveData: storage.save),
            sessionProvider: provider,
            config: Paykit.defaultConfig(receiverPath: PaykitReceiverPath.wallet)
        )

        sessionStorage.failDelete = true
        do {
            _ = try await sdk.forgetSessionAccess()
            XCTFail("Expected injected session deletion failure")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "session_clear_failed")
        }

        sessionStorage.failDelete = false
        _ = try await sdk.forgetSessionAccess()
        XCTAssertEqual(sessionStorage.deletedKeys.map(\.storageKey), ["paykit_session", "pubky_secret_key"])
        let status = try await sdk.identityStatus()
        let identity = try XCTUnwrap(status)
        XCTAssertNil(identity.publicKey)
        XCTAssertFalse(identity.liveSessionAvailable)
        XCTAssertNotNil(storage.data)
    }

    func testNativeSdkCanRetryAfterPlatformStorageFailure() async throws {
        for failLoad in [false, true] {
            let storage = Storage()
            let store = PaykitSdkStateBlobStore(loadData: storage.load, saveData: storage.save)
            let sdk = try PaykitSdk(
                stateStore: store, sessionProvider: NoSession(),
                config: Paykit.defaultConfig(receiverPath: PaykitReceiverPath.wallet)
            )
            storage.failLoad = failLoad
            storage.failSave = !failLoad
            do {
                _ = try await sdk.forgetSessionAccess()
                XCTFail("Expected injected storage failure")
            } catch let PaykitError.Storage(code, _) {
                XCTAssertEqual(code, failLoad ? "state_load_failed" : "state_save_failed")
            }
            storage.failLoad = false
            storage.failSave = false
            _ = try await sdk.forgetSessionAccess()
            _ = try await sdk.identityStatus()
            XCTAssertNotNil(storage.data)
        }
    }

    func testPlatformFailuresBecomeDeclaredStorageErrorsAndSdkErrorsArePreserved() throws {
        for error in [KeychainError.failedToLoad, .failedToSave, .failedToDelete] {
            do {
                let _: String = try paykitStorageCallback(code: "state_save_failed") { throw error }
                XCTFail("Expected storage failure")
            } catch let PaykitError.Storage(code, _) {
                XCTAssertEqual(code, "state_save_failed")
            }
        }
        do {
            let _: String = try paykitStorageCallback(code: "state_save_failed") {
                throw PaykitError.Storage(code: "revision_conflict", context: "State changed")
            }
            XCTFail("Expected revision conflict")
        } catch let PaykitError.Storage(code, context) {
            XCTAssertEqual(code, "revision_conflict")
            XCTAssertEqual(context, "State changed")
        }
        XCTAssertEqual(try paykitStorageCallback(code: "state_save_failed") { "healthy" }, "healthy")
    }
}
