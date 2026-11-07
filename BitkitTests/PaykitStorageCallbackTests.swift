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

    private enum SetupFailure: Error { case unavailable }

    func testLocalForgetDoesNotConstructAnSdkOrLoadRetainedSession() async throws {
        var deleted: [Bitkit.KeychainEntryType] = []
        var constructions = 0
        let provider = PaykitSdkSessionProvider(
            loadSessionSecret: {
                XCTFail("Local cleanup must not load the retained session")
                throw KeychainError.failedToLoad
            },
            deleteKeychainValue: { deleted.append($0) }
        )
        let service = PaykitSdkService(sessionProvider: provider, sdkFactory: {
            constructions += 1
            throw SetupFailure.unavailable
        })
        try await service.forgetSessionAccess()
        XCTAssertEqual(constructions, 0)
        XCTAssertEqual(deleted.map(\.storageKey), ["paykit_session", "pubky_secret_key"])
    }

    func testLocalForgetPreservesCredentialFailureAndAttemptsBothLocalKeys() async throws {
        var deleted: [Bitkit.KeychainEntryType] = []
        let provider = PaykitSdkSessionProvider(deleteKeychainValue: {
            deleted.append($0)
            if case .paykitSession = $0 {
                throw KeychainError.failedToDelete
            }
        })
        let service = PaykitSdkService(sessionProvider: provider, sdkFactory: { throw SetupFailure.unavailable })
        let version = await service.backupStateVersion
        do {
            try await service.forgetSessionAccess()
            XCTFail("Credential failure must remain visible to local completion")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "session_clear_failed")
        }
        XCTAssertEqual(deleted.map(\.storageKey), ["paykit_session", "pubky_secret_key"])
        let after = await service.backupStateVersion
        XCTAssertGreaterThan(after, version)
    }

    func testNativeProviderReturnsTypedAdmissionFailureWithoutAnUnexpectedCallbackError() async throws {
        let provider = PaykitSdkSessionProvider(loadSessionSecret: { nil })
        let sdk = try PaykitSdk.withPubkySharedState(sessionProvider: provider, config: Paykit.defaultConfig(appId: "bitkit"))
        provider.setAdmissionCheck { throw ProfileRemovalStore.StoreError.changed }
        do {
            _ = try await sdk.identityStatus()
            XCTFail("Revoked admission must not load credentials")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "profile_operation_unavailable")
        }
        provider.setAdmissionCheck(nil)
        let identity = try await sdk.identityStatus()
        XCTAssertNil(identity)
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
