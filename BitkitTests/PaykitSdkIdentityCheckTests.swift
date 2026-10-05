@testable import Bitkit
import Paykit
import XCTest

/// Writes made for one identity check, in the same locked SDK operation as the write, that the identity is still signed
/// in, so a sign-out and another identity's sign-in that land while the write waits make it write nothing.
final class PaykitSdkIdentityCheckTests: XCTestCase {
    func testContactSaveForAnIdentityThatIsNoLongerSignedInWritesNothing() async throws {
        for signedIn in [identityB, nil] {
            for restorePrivateConnection in [false, true] {
                let message = "\(signedIn == nil ? "after a sign-out" : "with another identity signed in"), restore \(restorePrivateConnection)"
                let sdk = IdentitySwitchingSdk(noPointer: .init())
                sdk.identity = signedIn
                let service = PaykitSdkService(sdkFactory: { sdk })

                do {
                    _ = try await service.saveContact(
                        publicKey: contactKey,
                        label: "Alice",
                        restorePrivateConnection: restorePrivateConnection,
                        expectedIdentity: identityA
                    )
                    XCTFail("Expected the save to be refused \(message)")
                } catch PubkyServiceError.identityChanged {
                } catch {
                    XCTFail("Expected identityChanged \(message), got \(error)")
                }
                XCTAssertEqual(sdk.writes, [], "Nothing is written \(message)")
                XCTAssertEqual(sdk.contactReads, 0, "It stops before it reads the next identity's contact \(message)")
            }
        }
    }

    func testContactSaveForTheSignedInIdentitySaves() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })

        let saved = try await service.saveContact(publicKey: contactKey, label: "Alice", expectedIdentity: bareIdentityA)
        _ = try await service.saveContact(publicKey: contactKey, label: "Unbound")

        XCTAssertEqual(saved.label, "Alice", "The identity matches in either key form")
        XCTAssertEqual(sdk.writes, ["save:Alice", "save:Unbound"], "A save for no identity saves for whichever one is signed in")
    }

    func testProfilePublicationForAnIdentityThatIsNoLongerSignedInWritesNothing() async throws {
        for signedIn in [identityB, nil] {
            let message = signedIn == nil ? "after a sign-out" : "with another identity signed in"
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = signedIn
            let service = PaykitSdkService(sdkFactory: { sdk })

            do {
                _ = try await service.publishPaykitProfile(testProfile, expectedIdentity: identityA)
                XCTFail("Expected the publication to be refused \(message)")
            } catch PubkyServiceError.identityChanged {
            } catch {
                XCTFail("Expected identityChanged \(message), got \(error)")
            }
            XCTAssertEqual(sdk.writes, [], "Nothing is written \(message)")
        }

        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.publishPaykitProfile(testProfile, expectedIdentity: bareIdentityA)
        _ = try await service.publishPaykitProfile(testProfile)
        XCTAssertEqual(sdk.writes, ["profile:Alice", "profile:Alice"], "A publication for the signed-in identity, or for none, publishes")
    }

    func testProfileAvatarUploadForAnIdentityThatIsNoLongerSignedInThrowsIdentityChanged() async throws {
        for signedIn in [identityB, nil] {
            let message = signedIn == nil ? "after a sign-out" : "with another identity signed in"
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = signedIn
            let service = PaykitSdkService(sdkFactory: { sdk })

            do {
                _ = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
                XCTFail("Expected the upload to be refused \(message)")
            } catch PubkyServiceError.identityChanged {
            } catch {
                XCTFail("Expected identityChanged \(message), got \(error)")
            }
            XCTAssertEqual(sdk.writes, [], "Nothing is written \(message)")
        }

        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        let uri = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: bareIdentityA)
        XCTAssertEqual(uri, "pubky://avatar")
        XCTAssertEqual(sdk.writes, ["upload"])
    }

    /// Without a live session, a profile or contact avatar upload for the signed-in identity fails with the SDK's own
    /// error, as it did before uploads were bound to an identity, so Edit Profile does not show a payment request error.
    /// The payment request upload still reports `requestUnavailable`.
    func testProfileAvatarUploadWithoutALiveSessionReportsTheSdksOwnError() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        sdk.hasLiveSession = false
        let service = PaykitSdkService(sdkFactory: { sdk })

        do {
            _ = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            XCTFail("Expected the upload to fail without a live session")
        } catch let error as PaykitError {
            guard case .Identity = error else { return XCTFail("Expected the SDK's identity error, got \(error)") }
            XCTAssertEqual(error.localizedDescription, noLiveSessionError.localizedDescription)
            XCTAssertNotEqual(error.localizedDescription, PaykitPaymentRequestError.requestUnavailable.localizedDescription)
        } catch {
            XCTFail("Expected the SDK's own error, got \(error)")
        }

        do {
            _ = try await service.uploadProfileAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            XCTFail("Expected the payment request upload to be refused")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable, "The payment request upload is unchanged")
        }
        XCTAssertEqual(sdk.writes, [])
    }

    /// The caller checked its session and started the write, which waits for the SDK lock while a sign-out and another
    /// identity's sign-in land. Only then does the write get the lock, so it must check the identity there.
    func testWriteThatAnIdentityChangeOvertakesWhileItWaitsForTheSdkLockWritesNothing() async throws {
        let writes: [(name: String, write: @Sendable (PaykitSdkService) async throws -> Void, isRefusal: @Sendable (Error) -> Bool)] = [
            ("contact save", { service in
                _ = try await service.saveContact(publicKey: contactKey, label: "Alice", expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError { return true }
                return false
            }),
            ("profile avatar upload", { service in
                _ = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError { return true }
                return false
            }),
            ("payment request upload", { service in
                _ = try await service.uploadProfileAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            }, { error in
                (error as? PaykitPaymentRequestError) == .requestUnavailable
            }),
            ("profile publication", { service in
                _ = try await service.publishPaykitProfile(testProfile, expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError { return true }
                return false
            }),
        ]
        for testCase in writes {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            let service = PaykitSdkService(sdkFactory: { sdk })
            await sdk.contactRecordsGate.close()
            let lockHolder = Task { try await service.contactRecords() }
            try await sdk.contactRecordsStarted.waitForEntries(count: 1)

            let write = Task { try await testCase.write(service) }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(sdk.writes, [], "\(testCase.name): the write waits for the SDK lock")
            sdk.identity = identityB

            await sdk.contactRecordsGate.open()
            _ = try await lockHolder.value
            switch await write.result {
            case .success:
                XCTFail("\(testCase.name): expected the write to be refused")
            case let .failure(error):
                XCTAssertTrue(testCase.isRefusal(error), "\(testCase.name): unexpected error \(error)")
            }
            XCTAssertEqual(sdk.writes, [], "\(testCase.name): nothing is written for the next identity")
        }
    }

    /// A sign-out queues for the SDK lock right behind a contact save. The lock is handed over in order, so the save runs
    /// first and saves while its identity is signed in. Were its identity checked in a locked operation of its own, the
    /// sign-out would take the lock between that check and the save, and the save would land after it.
    func testSignOutQueuedBehindAContactSaveCannotLandBetweenItsCheckAndItsWrite() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        await sdk.contactRecordsGate.close()
        let lockHolder = Task { try await service.contactRecords() }
        try await sdk.contactRecordsStarted.waitForEntries(count: 1)

        let save = Task { try await service.saveContact(publicKey: contactKey, label: "Alice", expectedIdentity: identityA) }
        try await Task.sleep(for: .milliseconds(50))
        let signOut = Task { try await service.signOut() }
        try await Task.sleep(for: .milliseconds(50))

        await sdk.contactRecordsGate.open()
        _ = try await lockHolder.value
        try await signOut.value
        let saveResult = await save.result

        XCTAssertNil(sdk.identity, "The sign-out ran")
        XCTAssertNoThrow(try saveResult.get(), "The save got the lock first, while its identity was signed in")
        XCTAssertEqual(sdk.writes, ["save:Alice"])
        XCTAssertEqual(sdk.identitiesAtWrites, [identityA], "Nothing is written once the identity signed out")
    }
}

private let identityA = "pubky8qd4tbz3hyafi7h7hoqwd5hm7tsaz1n7txcyojmd4kxf9xp7mgro"
private let bareIdentityA = "8qd4tbz3hyafi7h7hoqwd5hm7tsaz1n7txcyojmd4kxf9xp7mgro"
private let identityB = "pubkyc1nbnzsfgm1g1rf9um6nh5mdtdhq8mz5i5o4r6g8x4qzi3uqhdmo"
private let contactKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
private let testProfile = PaykitProfile(displayName: "Alice", imageUri: nil, extraJson: nil)
/// What the SDK reports for a blob upload without a live Pubky session.
private let noLiveSessionError = PaykitError.Identity(
    code: "identity_error",
    context: "cannot publish Paykit blob without an active Pubky session"
)

/// Holds every call that waits on it while closed.
private actor IdentityCheckGate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() {
        isOpen = false
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct IdentityCheckTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Counts calls and lets a test wait until enough have started, failing instead of hanging.
private actor IdentityCheckCallLog {
    private(set) var count = 0

    func record() {
        count += 1
    }

    func waitForEntries(count expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count < expected {
            guard ContinuousClock.now < deadline else {
                throw IdentityCheckTimeout(description: "Timed out waiting for \(expected) calls; saw \(count)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// An SDK signed in as `identity`, which a test changes as a sign-out and another identity's sign-in would. A contact
/// records read waits on its gate, keeping the SDK lock meanwhile. It records each write that reaches it.
private final class IdentitySwitchingSdk: PaykitSdk, @unchecked Sendable {
    private let lock = NSLock()
    private var signedInIdentity: String?
    private var liveSession = true
    private var recordedWrites: [String] = []
    private var recordedIdentitiesAtWrites: [String?] = []
    private var recordedContactReads = 0
    let contactRecordsGate = IdentityCheckGate()
    let contactRecordsStarted = IdentityCheckCallLog()

    var identity: String? {
        get { lock.withLock { signedInIdentity } }
        set { lock.withLock { signedInIdentity = newValue } }
    }

    var hasLiveSession: Bool {
        get { lock.withLock { liveSession } }
        set { lock.withLock { liveSession = newValue } }
    }

    var writes: [String] {
        lock.withLock { recordedWrites }
    }

    /// The identity signed in as each write landed.
    var identitiesAtWrites: [String?] {
        lock.withLock { recordedIdentitiesAtWrites }
    }

    var contactReads: Int {
        lock.withLock { recordedContactReads }
    }

    private func recordWrite(_ write: String) {
        lock.withLock {
            recordedWrites.append(write)
            recordedIdentitiesAtWrites.append(signedInIdentity)
        }
    }

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: identity, capability: identity != nil && hasLiveSession ? .publicOnly : .signedOut)
    }

    override func backupStateRevision() async throws -> String {
        "revision"
    }

    override func stateRevision() throws -> String? {
        nil
    }

    override func signOut() async throws -> IdentityStatus {
        identity = nil
        return IdentityStatus(publicKey: nil, capability: .signedOut)
    }

    override func contactRecords() async throws -> [ContactRecord] {
        await contactRecordsStarted.record()
        await contactRecordsGate.wait()
        return []
    }

    override func contactRecord(publicKey: String) async throws -> ContactRecord? {
        lock.withLock { recordedContactReads += 1 }
        return Self.record(publicKey: publicKey, label: "Contact")
    }

    override func linkedPeers() async throws -> [LinkedPeerRecord] {
        []
    }

    override func saveContact(update: ContactUpdate) async throws -> ContactRecord {
        recordWrite("save:\(update.label ?? "")")
        return Self.record(publicKey: update.publicKey, label: update.label)
    }

    override func uploadProfileAvatar(bytes: Data, contentType _: String) async throws -> PaykitBlobRecord {
        guard identity != nil, hasLiveSession else { throw noLiveSessionError }
        recordWrite("upload")
        return PaykitBlobRecord(
            publicKey: identity ?? "", path: "/pub/paykit/blobs/avatar.jpg", uri: "pubky://avatar",
            sizeBytes: UInt64(bytes.count), updatedAt: "2026-10-02T00:00:00Z"
        )
    }

    override func fetchPaykitProfile(publicKey _: String) async throws -> PaykitProfileRecord? {
        nil
    }

    override func publishPaykitProfile(profile: PaykitProfile, expectedRevision _: String?) async throws -> PaykitProfileRecord {
        recordWrite("profile:\(profile.displayName ?? "")")
        return PaykitProfileRecord(
            publicKey: identity ?? "",
            profile: profile,
            path: "/pub/paykit/profile.json",
            revision: "test",
            updatedAt: "2026-10-02T00:00:00Z"
        )
    }

    private static func record(publicKey: String, label: String?) -> ContactRecord {
        ContactRecord(
            publicKey: publicKey, label: label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-10-02T00:00:00Z", updatedAt: "2026-10-02T00:00:00Z",
            publicContactMarkerStatus: .notPublished,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
    }
}
