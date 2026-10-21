@testable import Bitkit
import Paykit
import XCTest

final class PaykitStorageCallbackTests: XCTestCase {
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
        let sessionStorage = SessionStorage()
        let provider = PaykitSdkSessionProvider(
            loadSessionSecret: sessionStorage.loadSessionSecret,
            deleteKeychainValue: sessionStorage.deleteKeychainValue
        )
        let sdk = try PaykitSdk.withPubkySharedState(sessionProvider: provider, config: Paykit.defaultConfig(appId: "bitkit"))

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
    }

    func testNativeSdkCanRetryAfterProductionSessionClearFailure() async throws {
        let sessionStorage = SessionStorage()
        let provider = PaykitSdkSessionProvider(
            loadSessionSecret: sessionStorage.loadSessionSecret,
            deleteKeychainValue: sessionStorage.deleteKeychainValue
        )
        let sdk = try PaykitSdk.withPubkySharedState(sessionProvider: provider, config: Paykit.defaultConfig(appId: "bitkit"))

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
        XCTAssertEqual(identity.capability, .signedOut)
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
