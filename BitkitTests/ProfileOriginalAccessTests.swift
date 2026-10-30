@testable import Bitkit
import Paykit
import XCTest

final class ProfileOriginalAccessTests: XCTestCase {
    private var owner: String {
        get throws { try SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: String(repeating: "01", count: 32)) }
    }

    private final class Access: PubkySessionAccess, @unchecked Sendable {
        var secret = "original-session"
        var key: PaykitIdentitySecretKey?

        convenience init(secret: String = "original-session", key: PaykitIdentitySecretKey? = nil) {
            self.init(noPointer: .init())
            self.secret = secret
            self.key = key
        }

        override func exportSessionSecret() -> String {
            secret
        }

        override func exportPaykitIdentitySecretKey() -> PaykitIdentitySecretKey? {
            key
        }

        override func withPaykitIdentitySecretKey(key: PaykitIdentitySecretKey) -> PubkySessionAccess {
            Access(secret: secret, key: key)
        }
    }

    private final class Storage {
        var session: String? = "original-session"
        var credential: Data? = Data(String(repeating: "01", count: 32).utf8)
        var failLoad = false
        var failCredentialLoad = false
        var adopted: PaykitSdkSessionProvider.AdoptedCredential?
        var failAdoptedLoad = false
        var adoptedReads = 0
        var onAdoptedRead: (() throws -> Void)?
        var onDelete: ((Bitkit.KeychainEntryType) throws -> Void)?
        var deleted: [String] = []
        var failAfterSessionDelete = false
        var replaceCredentialAfterSessionDelete = false

        func provider() -> PaykitSdkSessionProvider {
            let result = PaykitSdkSessionProvider(loadSessionSecret: {
                if self.failLoad {
                    throw KeychainError.failedToLoad
                }
                return self.session
            }, loadLocalCredential: {
                if self.failCredentialLoad {
                    throw KeychainError.failedToLoad
                }
                return self.credential
            }, loadAdoptedReference: { self.adopted?.reference }, loadAdoptedCredential: { _ in
                self.adoptedReads += 1
                try self.onAdoptedRead?()
                if self.failAdoptedLoad {
                    throw KeychainError.failedToLoad
                }
                return self.adopted
            },
            deleteKeychainValue: { key in
                self.deleted.append(key.storageKey)
                try self.onDelete?(key)
                if case .paykitSession = key {
                    self.session = nil
                    if self.replaceCredentialAfterSessionDelete {
                        self.credential = Data([9])
                    }
                    if self.failAfterSessionDelete {
                        throw KeychainError.failedToDelete
                    }
                } else {
                    self.credential = nil
                }
            })
            result.setLiveSessionAccess(Access())
            return result
        }
    }

    private final class Logout: PubkyGrantLogout, @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        var isRevoked: Bool {
            lock.withLock { revoked }
        }

        override func revokeAdmission() {
            lock.withLock { revoked = true }
        }
    }

    func testObservedCredentialMismatchCannotReviveCaptureByRestoringBytes() throws {
        for replaceSession in [false, true] {
            let storage = Storage()
            let provider = storage.provider()
            let original = try provider.captureOriginalAccess(expectedOwner: owner)
            let logout = Logout(noPointer: .init())
            let registration = try provider.registerGrantLogout(logout, access: original)
            defer { provider.unregisterGrantLogout(registration) }
            let session = storage.session
            let credential = storage.credential
            if replaceSession {
                storage.session = "replacement"
            } else {
                storage.credential = Data([9])
            }
            XCTAssertThrowsError(try provider.validateOriginalAccess(original))
            storage.session = session
            storage.credential = credential
            XCTAssertThrowsError(try provider.validateOriginalAccess(original), "Restored bytes cannot revive an observed ended capture")
            XCTAssertTrue(logout.isRevoked, "Observed mismatch must also revoke the retained native handle")
            XCTAssertThrowsError(try provider.clearOriginalAccess(original))
            XCTAssertTrue(storage.deleted.isEmpty)
        }
    }

    func testReadFailureCannotReviveCaptureWhenStorageRecovers() throws {
        let storage = Storage()
        let provider = storage.provider()
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        let logout = Logout(noPointer: .init())
        let registration = try provider.registerGrantLogout(logout, access: original)
        defer { provider.unregisterGrantLogout(registration) }
        storage.failLoad = true
        XCTAssertThrowsError(try provider.validateOriginalAccess(original))
        storage.failLoad = false
        XCTAssertThrowsError(try provider.validateOriginalAccess(original))
        XCTAssertTrue(logout.isRevoked)
        XCTAssertThrowsError(try provider.clearOriginalAccess(original))
        XCTAssertTrue(storage.deleted.isEmpty)
    }

    func testObservedAdoptedSourceOrSecretReplacementCannotReviveCapture() throws {
        let originalSource = PaykitSdkSessionProvider.AdoptedCredential(sourceApp: "ring", publicKey: "owner", secret: "original")
        let replacements: [PaykitSdkSessionProvider.AdoptedCredential?] = [
            .init(sourceApp: "other-app", publicKey: "owner", secret: "original"),
            .init(sourceApp: "ring", publicKey: "other-owner", secret: "original"),
            .init(sourceApp: "ring", publicKey: "owner", secret: "replacement"), nil,
        ]
        for replacement in replacements {
            let storage = Storage()
            storage.adopted = originalSource
            let provider = storage.provider()
            let original = try provider.captureOriginalAccess(expectedOwner: owner)
            let logout = Logout(noPointer: .init())
            let registration = try provider.registerGrantLogout(logout, access: original)
            defer { provider.unregisterGrantLogout(registration) }
            storage.adopted = replacement
            XCTAssertThrowsError(try provider.validateOriginalAccess(original))
            storage.adopted = originalSource
            XCTAssertThrowsError(try provider.validateOriginalAccess(original))
            if replacement?.reference == originalSource.reference {
                try provider.clearOriginalAccess(original)
            } else {
                XCTAssertThrowsError(try provider.clearOriginalAccess(original))
            }
            XCTAssertTrue(logout.isRevoked)
            XCTAssertEqual(storage.deleted.isEmpty, replacement?.reference != originalSource.reference)
        }
    }

    func testAdoptedReadFailureRetiresAllCapturesFromTheObservedEpoch() throws {
        let storage = Storage()
        storage.adopted = .init(sourceApp: "ring", publicKey: "owner", secret: "original")
        let provider = storage.provider()
        let originals = try [provider.captureOriginalAccess(expectedOwner: owner), provider.captureOriginalAccess(expectedOwner: owner)]
        let logouts = [Logout(noPointer: .init()), Logout(noPointer: .init())]
        let registrations = try zip(originals, logouts).map { try provider.registerGrantLogout($1, access: $0) }
        defer { registrations.forEach { provider.unregisterGrantLogout($0) } }
        storage.failAdoptedLoad = true
        XCTAssertThrowsError(try provider.validateOriginalAccess(originals[0]))
        storage.failAdoptedLoad = false
        for original in originals {
            XCTAssertThrowsError(try provider.validateOriginalAccess(original))
        }
        XCTAssertTrue(logouts.allSatisfy(\.isRevoked))
    }

    func testOldCaptureValidationCannotRevokeANewerProviderEpoch() throws {
        let storage = Storage()
        let provider = storage.provider()
        let old = try provider.captureOriginalAccess(expectedOwner: owner)
        provider.setLiveSessionAccess(Access())
        let current = try provider.captureOriginalAccess(expectedOwner: owner)
        let logout = Logout(noPointer: .init())
        let registration = try provider.registerGrantLogout(logout, access: current)
        defer { provider.unregisterGrantLogout(registration) }
        XCTAssertThrowsError(try provider.validateOriginalAccess(old))
        XCTAssertNoThrow(try provider.validateOriginalAccess(current))
        XCTAssertFalse(logout.isRevoked)
    }

    func testRingLossEndsRemoteAdmissionButDoesNotBlockOwnedLocalErase() throws {
        let storage = Storage()
        storage.adopted = .init(sourceApp: "ring", publicKey: "owner", secret: "original")
        let provider = storage.provider()
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        let logout = Logout(noPointer: .init())
        let registration = try provider.registerGrantLogout(logout, access: original)
        defer { provider.unregisterGrantLogout(registration) }
        storage.failAdoptedLoad = true
        XCTAssertThrowsError(try provider.validateOriginalAccess(original))
        XCTAssertTrue(logout.isRevoked)
        storage.failAdoptedLoad = false
        XCTAssertThrowsError(try provider.validateOriginalAccess(original), "Restoring Ring cannot revive remote admission")
        storage.failAdoptedLoad = true
        let foreignReads = storage.adoptedReads
        try provider.clearOriginalAccess(original)
        XCTAssertEqual(storage.adoptedReads, foreignReads, "Local erase must not read Ring")
        XCTAssertNil(storage.session)
        XCTAssertNil(storage.credential)
        XCTAssertEqual(storage.adopted?.sourceApp, "ring", "Foreign material remains untouched")
    }

    func testReferenceChangeObservedByForeignReaderPermanentlyEndsOwnedErase() throws {
        let storage = Storage()
        let source = PaykitSdkSessionProvider.AdoptedCredential(sourceApp: "ring", publicKey: "owner", secret: "original")
        storage.adopted = source
        let provider = storage.provider()
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        let logout = Logout(noPointer: .init())
        let registration = try provider.registerGrantLogout(logout, access: original)
        defer { provider.unregisterGrantLogout(registration) }
        storage.onAdoptedRead = { storage.adopted = .init(sourceApp: "replacement", publicKey: "owner", secret: "original") }
        XCTAssertThrowsError(try provider.validateOriginalAccess(original))
        storage.onAdoptedRead = nil
        storage.adopted = source
        XCTAssertThrowsError(try provider.clearOriginalAccess(original))
        XCTAssertTrue(logout.isRevoked)
        XCTAssertTrue(storage.deleted.isEmpty)
    }

    func testForeignLookupUsesOnlyTheSuppliedOriginalReference() throws {
        let reference = PaykitSdkSessionProvider.AdoptedReference(sourceApp: "original-ring", publicKey: "original-owner")
        var reads = 0
        let credential = try PaykitSdkSessionProvider.AdoptedCredential.load(reference: reference) { source, key in
            reads += 1
            XCTAssertEqual(source, reference.sourceApp)
            XCTAssertEqual(key, reference.publicKey)
            return "original"
        }
        XCTAssertEqual(credential?.reference, reference)
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try PaykitSdkSessionProvider.AdoptedCredential.load(reference: nil) { _, _ in
            XCTFail("No reference means no foreign account read")
            return nil
        })
    }

    func testCaptureRejectsSelectedStoredCredentialForAnotherOwner() throws {
        for adopted in [false, true] {
            let storage = Storage()
            let secret = String(repeating: "02", count: 32)
            if adopted {
                storage.credential = nil
                storage.adopted = try .init(sourceApp: "ring", publicKey: SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: secret), secret: secret)
            } else {
                storage.credential = Data(secret.utf8)
            }
            let provider = storage.provider()
            XCTAssertThrowsError(try provider.captureOriginalAccess(expectedOwner: owner))
            XCTAssertTrue(storage.deleted.isEmpty)
        }
    }

    func testDeleteErrorReadbackMismatchOrFailurePermanentlyEndsConditionalErase() throws {
        for target in [Bitkit.KeychainEntryType.paykitSession, .pubkySecretKey] {
            for unreadable in [false, true] {
                let storage = Storage()
                let provider = storage.provider()
                let original = try provider.captureOriginalAccess(expectedOwner: owner)
                let credential = storage.credential
                storage.onDelete = { key in
                    guard key.storageKey == target.storageKey else { return }
                    if case .paykitSession = key {
                        if unreadable {
                            storage.failLoad = true
                        } else {
                            storage.session = "replacement"
                        }
                    } else {
                        if unreadable {
                            storage.failCredentialLoad = true
                        } else {
                            storage.credential = Data([9])
                        }
                    }
                    throw KeychainError.failedToDelete
                }
                XCTAssertThrowsError(try provider.clearOriginalAccess(original))
                let deletions = storage.deleted
                storage.onDelete = nil
                storage.failLoad = false
                storage.failCredentialLoad = false
                storage.session = target.storageKey == "paykit_session" ? "original-session" : nil
                storage.credential = credential
                XCTAssertThrowsError(try provider.clearOriginalAccess(original), "Restored bytes cannot hide a failed-delete readback mismatch")
                XCTAssertEqual(storage.deleted, deletions)
            }
        }
    }

    func testFailedDeleteWithUnchangedOrOwnDeletedValueStillAllowsLocalCompletion() throws {
        for target in [Bitkit.KeychainEntryType.paykitSession, .pubkySecretKey] {
            for deleted in [false, true] {
                let storage = Storage()
                let provider = storage.provider()
                let original = try provider.captureOriginalAccess(expectedOwner: owner)
                storage.onDelete = { key in
                    guard key.storageKey == target.storageKey else { return }
                    if deleted {
                        if case .paykitSession = key {
                            storage.session = nil
                        } else {
                            storage.credential = nil
                        }
                    }
                    throw KeychainError.failedToDelete
                }
                XCTAssertThrowsError(try provider.clearOriginalAccess(original))
                storage.onDelete = nil
                try provider.clearOriginalAccess(original)
                XCTAssertNil(storage.session)
                XCTAssertNil(storage.credential)
            }
        }
    }

    func testCaptureAcceptsMatchingAdoptedOwnerWithoutALocalRoot() throws {
        let storage = Storage()
        storage.credential = nil
        storage.adopted = try .init(sourceApp: "ring", publicKey: owner, secret: String(repeating: "01", count: 32))
        let provider = storage.provider()
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        XCTAssertNoThrow(try provider.validateOriginalAccess(original))
    }

    func testOnlyCancellationLeavesMatchingCaptureAdmittedAfterValidationFailure() throws {
        for cancellation in [false, true] {
            let storage = Storage()
            let provider = storage.provider()
            let original = try provider.captureOriginalAccess(expectedOwner: owner)
            let logout = Logout(noPointer: .init())
            let registration = try provider.registerGrantLogout(logout, access: original)
            defer { provider.unregisterGrantLogout(registration) }
            provider.setAdmissionCheck {
                if cancellation {
                    throw CancellationError()
                }
                throw ProfileRemovalStore.StoreError.changed
            }
            XCTAssertThrowsError(try provider.validateOriginalAccess(original)) { error in
                XCTAssertEqual(error is CancellationError, cancellation)
            }
            provider.setAdmissionCheck(nil)
            if cancellation {
                XCTAssertNoThrow(try provider.validateOriginalAccess(original))
                XCTAssertFalse(logout.isRevoked)
            } else {
                XCTAssertThrowsError(try provider.validateOriginalAccess(original))
                XCTAssertTrue(logout.isRevoked)
            }
        }
    }

    func testAdoptedCredentialCaptureReadsOnlyTheExactReferencedAccountAndRejectsIncompleteSources() throws {
        let suite = "original-access-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        let read: (String, String) throws -> String? = { source, key in
            reads += 1
            XCTAssertEqual(source, "ring")
            XCTAssertEqual(key, "owner")
            return "original"
        }
        XCTAssertNil(try PaykitSdkSessionProvider.AdoptedCredential.load(defaults: defaults, readSecret: read))
        defaults.set("ring", forKey: AdoptedPubkyReference.sourceAppKey)
        XCTAssertThrowsError(try PaykitSdkSessionProvider.AdoptedCredential.load(defaults: defaults, readSecret: read))
        XCTAssertEqual(reads, 0)
        defaults.set("owner", forKey: AdoptedPubkyReference.pubkyKey)
        XCTAssertEqual(try PaykitSdkSessionProvider.AdoptedCredential.load(defaults: defaults, readSecret: read),
                       .init(sourceApp: "ring", publicKey: "owner", secret: "original"))
        XCTAssertEqual(reads, 1)
        XCTAssertThrowsError(try PaykitSdkSessionProvider.AdoptedCredential.load(defaults: defaults, readSecret: { _, _ in nil }))
        defaults.set(Data([1]), forKey: AdoptedPubkyReference.sourceAppKey)
        XCTAssertThrowsError(try PaykitSdkSessionProvider.AdoptedCredential.load(defaults: defaults, readSecret: read))
        XCTAssertEqual(reads, 1)
    }

    func testKeyAttachmentClonesCurrentAccessWithoutDiscardingIt() throws {
        let storage = Storage()
        let provider = storage.provider()
        let original = try XCTUnwrap(provider.loadSessionAccess())
        let key = try PaykitIdentitySecretKey(bytes: Data(repeating: 7, count: 32), keyGeneration: 3)
        provider.setPaykitIdentitySecretKey(key)
        let attached = try XCTUnwrap(provider.loadSessionAccess())
        XCTAssertFalse(original === attached)
        XCTAssertTrue(attached is Access, "Attachment must preserve the access object through the native clone API")
        XCTAssertNil(original.exportPaykitIdentitySecretKey())
        XCTAssertEqual(attached.exportPaykitIdentitySecretKey()?.exportBytes(), key.exportBytes())
        XCTAssertEqual(attached.exportSessionSecret(), original.exportSessionSecret())
    }

    func testSameGenerationSignerReplacementInvalidatesOriginalCapture() throws {
        let storage = Storage()
        let provider = storage.provider()
        try provider.setPaykitIdentitySecretKey(.init(bytes: Data(repeating: 1, count: 32), keyGeneration: 3))
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        try provider.setPaykitIdentitySecretKey(.init(bytes: Data(repeating: 2, count: 32), keyGeneration: 3))
        XCTAssertThrowsError(try provider.validateOriginalAccess(original))
        XCTAssertThrowsError(try provider.clearOriginalAccess(original))
        XCTAssertTrue(storage.deleted.isEmpty)
    }

    func testReplacementCredentialsOrSameSecretLifecycleCannotBeErasedByOriginalCapture() throws {
        for replacement in 0 ..< 4 {
            let storage = Storage()
            let provider = storage.provider()
            let original = try provider.captureOriginalAccess(expectedOwner: owner)
            switch replacement {
            case 0: storage.session = "replacement-session"
            case 1: storage.credential = Data([9])
            case 2: provider.setLiveSessionAccess(Access())
            default: provider.suspendStoredSessionAccess(); provider.resumeStoredSessionAccess()
            }
            XCTAssertThrowsError(try provider.validateOriginalAccess(original))
            XCTAssertThrowsError(try provider.clearOriginalAccess(original))
            XCTAssertTrue(storage.deleted.isEmpty)
        }
    }

    func testConditionalEraseTracksOwnPartialDeletionAndCannotEraseAnInterveningReplacement() throws {
        for replacement in [false, true] {
            let storage = Storage()
            let provider = storage.provider()
            let original = try provider.captureOriginalAccess(expectedOwner: owner)
            storage.failAfterSessionDelete = true
            XCTAssertThrowsError(try provider.clearOriginalAccess(original))
            XCTAssertNil(storage.session)
            XCTAssertNotNil(storage.credential)
            storage.failAfterSessionDelete = false
            if replacement {
                storage.session = "replacement-session"
                XCTAssertThrowsError(try provider.clearOriginalAccess(original))
                XCTAssertEqual(storage.deleted, ["paykit_session"])
                XCTAssertNotNil(storage.credential)
            } else {
                try provider.clearOriginalAccess(original)
                XCTAssertNil(storage.credential)
                XCTAssertEqual(storage.deleted, ["paykit_session", "paykit_session", "pubky_secret_key"])
            }
        }
    }

    func testConditionalEraseRechecksRemainingCredentialBetweenDeletes() throws {
        let storage = Storage()
        let provider = storage.provider()
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        storage.replaceCredentialAfterSessionDelete = true
        XCTAssertThrowsError(try provider.clearOriginalAccess(original))
        XCTAssertEqual(storage.credential, Data([9]))
        XCTAssertEqual(storage.deleted, ["paykit_session"])
    }

    func testConditionalEraseRequiresAdmissionEvenAfterOriginalCapture() throws {
        let storage = Storage()
        let provider = storage.provider()
        let original = try provider.captureOriginalAccess(expectedOwner: owner)
        provider.setAdmissionCheck { throw ProfileRemovalStore.StoreError.changed }
        XCTAssertThrowsError(try provider.clearOriginalAccess(original))
        XCTAssertTrue(storage.deleted.isEmpty)
    }
}
