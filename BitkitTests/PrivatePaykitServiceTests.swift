@testable import Bitkit
import Combine
import Paykit
import XCTest

final class PrivatePaykitServiceTests: XCTestCase {
    func testRoleSelectionUsesLexicographicPubkyKeys() {
        let lower = "pubky1111111111111111111111111111111111111111111111111111"
        let higher = "pubkyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

        XCTAssertTrue(PrivatePaykitService.shouldInitiate(ownPublicKey: higher, remotePublicKey: lower))
        XCTAssertFalse(PrivatePaykitService.shouldInitiate(ownPublicKey: lower, remotePublicKey: higher))
    }

    func testPrivatePayloadLimitAcceptsV1EndpointMap() throws {
        let invoicePayload = try PublicPaykitService.serializePayload(value: "lnbc1privateinvoice")
        let addressPayload = try PublicPaykitService.serializePayload(value: "bcrt1qprivateaddress")

        XCTAssertTrue(
            PrivatePaykitService.isNoisePayloadWithinLimit([
                PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue: invoicePayload,
                PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue: addressPayload,
            ])
        )
    }

    func testPrivatePayloadLimitRejectsOversizedEndpointMap() {
        XCTAssertFalse(
            PrivatePaykitService.isNoisePayloadWithinLimit([
                PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue: String(repeating: "x", count: 1200),
            ])
        )
    }

    func testPrivateRemovalTombstoneMapFitsNoisePayloadLimitAndIsNotPayable() {
        let tombstonePayload = #"{"value":""}"#
        let tombstoneMap = Dictionary(uniqueKeysWithValues: PublicPaykitService.MethodId.publishableMethodIds.map {
            ($0.rawValue, tombstonePayload)
        })

        XCTAssertTrue(PrivatePaykitService.isNoisePayloadWithinLimit(tombstoneMap))
        XCTAssertNil(
            PublicPaykitService.parseEndpoint(
                methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                endpointData: tombstonePayload
            )
        )
    }

    func testRecoveryMarkerPathIsStableAndDirectional() throws {
        let alice = "pubky1111111111111111111111111111111111111111111111111111"
        let bob = "pubkyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

        let aliceToBob = try XCTUnwrap(PrivatePaykitService.recoveryMarkerPath(from: alice, to: bob))
        let aliceToBobAgain = try XCTUnwrap(PrivatePaykitService.recoveryMarkerPath(from: alice, to: bob))
        let bobToAlice = try XCTUnwrap(PrivatePaykitService.recoveryMarkerPath(from: bob, to: alice))

        XCTAssertEqual(aliceToBob, aliceToBobAgain)
        XCTAssertNotEqual(aliceToBob, bobToAlice)
        XCTAssertTrue(aliceToBob.hasPrefix("/pub/paykit/v0/private-recovery/"))
        XCTAssertTrue(aliceToBob.hasSuffix(".json"))
    }

    func testNewerRecoveryMarkerReplacesRecentlyCompletedLink() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: [:],
                linkCompletedAt: 100,
                handshakeUpdatedAt: nil,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil
            ),
        ])

        let marker = PrivatePaykitService.RecoveryMarker(version: 1, path: "", stage: "init", attemptId: "attempt", createdAt: 101)

        let shouldReplace = await service.shouldReplaceUsableLink(with: marker, publicKey: publicKey)

        XCTAssertTrue(shouldReplace)
    }

    func testStaleLinkFailureClassificationUsesTypedPaykitErrors() async {
        let service = PrivatePaykitService()
        let noiseFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Transport(reason: "bad mac while decrypting payload"))
        let linkHandleFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Validation(reason: "Unknown encrypted-link handle: 123"))
        let counterFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Transport(reason: "counter mismatch"))
        let networkFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Transport(reason: "connection timed out"))
        let sessionFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Session(reason: "No active session"))

        XCTAssertTrue(noiseFailure)
        XCTAssertTrue(linkHandleFailure)
        XCTAssertFalse(counterFailure)
        XCTAssertFalse(networkFailure)
        XCTAssertFalse(sessionFailure)
    }

    func testHandshakeTransportNotReadyIsPendingNotStaleState() async {
        let service = PrivatePaykitService()
        let error = PaykitFfiError
            .Transport(reason: "failed to transition to transport mode: IsHandshake: pubky-noise transition_transport failed: IsHandshake")
        let isPending = await service.isEncryptedHandshakePendingError(error)
        let isStaleState = await service.isEncryptedHandshakeStateFailure(error)

        XCTAssertTrue(isPending)
        XCTAssertFalse(isStaleState)
    }

    func testDuplicatePaymentErrorClassificationUsesWrappedAppErrorReason() {
        XCTAssertTrue(
            PrivatePaykitService.isDuplicatePaymentError(
                AppError(message: "Lightning payment failed", debugMessage: "Duplicate payment")
            )
        )

        XCTAssertFalse(
            PrivatePaykitService.isDuplicatePaymentError(
                AppError(message: "Lightning payment failed", debugMessage: "Route not found")
            )
        )
    }

    func testReceivedPrivateInvoiceHashKeepsContactAttribution() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycontact"

        await service.rememberReceivedInvoicePaymentHash("payment-hash", publicKey: publicKey)

        let matchedPublicKey = await service.contactPublicKey(forPrivateInvoicePaymentHash: "payment-hash")
        XCTAssertEqual(matchedPublicKey, publicKey)
    }

    func testWalletBackupDecodesExistingPayloadWithoutPrivatePaykitFields() throws {
        let data = #"{"version":1,"createdAt":123,"transfers":[]}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertTrue(payload.transfers.isEmpty)
        XCTAssertNil(payload.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertNil(payload.privatePaykitContactLinks)
    }

    func testWalletBackupRoundTripsPrivateReservationCeiling() throws {
        let backup = WalletBackupV1(
            version: 1,
            createdAt: 123,
            transfers: [],
            privatePaykitHighestReservedReceiveIndexByAddressType: ["nativeSegwit": 5],
            privatePaykitContactLinks: nil
        )

        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertEqual(decoded.version, backup.version)
        XCTAssertEqual(decoded.createdAt, backup.createdAt)
        XCTAssertTrue(decoded.transfers.isEmpty)
        XCTAssertEqual(decoded.privatePaykitHighestReservedReceiveIndexByAddressType, backup.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertNil(decoded.privatePaykitContactLinks)
    }

    func testReservationStoreBacksUpRestoredCeiling() async throws {
        let suiteName = "PrivatePaykitServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PrivatePaykitAddressReservationStore(defaults: defaults)
        await store.restoreBackup(["nativeSegwit": 5])

        let snapshot = await store.backupSnapshot()
        XCTAssertEqual(snapshot?["nativeSegwit"], 5)
        XCTAssertNil(snapshot?["taproot"])
    }

    func testWalletBackupRoundTripsPrivateContactLinks() throws {
        let backup = WalletBackupV1(
            version: 1,
            createdAt: 123,
            transfers: [],
            privatePaykitHighestReservedReceiveIndexByAddressType: nil,
            privatePaykitContactLinks: [
                "pubkycontact": PrivatePaykitContactLinkBackupV1(
                    publicKey: "pubkycontact",
                    linkSnapshotHex: "abcd",
                    handshakeSnapshotHex: nil,
                    remoteEndpoints: [
                        PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue: #"{"value":"lnbc1cached"}"#,
                        PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue: #"{"value":"bcrt1qcached"}"#,
                    ],
                    linkCompletedAt: 456,
                    handshakeUpdatedAt: 123,
                    recoveryStartedAt: 789,
                    mainRecoveryAttemptId: "main-attempt",
                    responderRecoveryAttemptId: "responder-attempt",
                    awaitingRecoveredRemoteEndpoints: true
                ),
            ]
        )

        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertEqual(decoded.version, backup.version)
        XCTAssertEqual(decoded.createdAt, backup.createdAt)
        XCTAssertTrue(decoded.transfers.isEmpty)
        XCTAssertNil(decoded.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertEqual(decoded.privatePaykitContactLinks, backup.privatePaykitContactLinks)
        XCTAssertEqual(decoded.privatePaykitContactLinks?["pubkycontact"]?.awaitingRecoveredRemoteEndpoints, true)
    }

    func testPrivatePaykitStateStoresOnlySnapshotsInKeychainState() throws {
        let publicKey = "pubkycontact"
        var contactState = PrivatePaykitService.ContactState()
        contactState.linkSnapshotHex = "secret-link"
        contactState.handshakeSnapshotHex = "secret-handshake"
        contactState.remoteEndpoints = [
            PrivatePaykitService.StoredPaymentEntry(
                methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                endpointData: #"{"value":"lnbc1cached"}"#
            ),
        ]
        contactState.localInvoice = PrivatePaykitService.StoredInvoice(bolt11: "lnbc1local", paymentHash: "hash", expiresAt: 123)
        contactState.lastLocalPayloadHash = "payload-hash"

        let state = PrivatePaykitService.PrivatePaykitState(contacts: [publicKey: contactState])
        let secretData = try JSONEncoder().encode(state.secretState)
        let cacheData = try JSONEncoder().encode(state.cacheState)
        let secretJson = try XCTUnwrap(String(data: secretData, encoding: .utf8))
        let cacheJson = try XCTUnwrap(String(data: cacheData, encoding: .utf8))

        XCTAssertTrue(secretJson.contains("secret-link"))
        XCTAssertTrue(secretJson.contains("secret-handshake"))
        XCTAssertFalse(secretJson.contains("lnbc1cached"))
        XCTAssertFalse(secretJson.contains("lnbc1local"))
        XCTAssertFalse(secretJson.contains("payload-hash"))

        XCTAssertTrue(cacheJson.contains("lnbc1cached"))
        XCTAssertTrue(cacheJson.contains("lnbc1local"))
        XCTAssertTrue(cacheJson.contains("payload-hash"))
        XCTAssertFalse(cacheJson.contains("secret-link"))
        XCTAssertFalse(cacheJson.contains("secret-handshake"))
    }

    func testCloseAndClearCanMarkProfileRecoveryPendingWhenPrivateContactStateExists() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: [:],
                linkCompletedAt: 123,
                handshakeUpdatedAt: nil,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil
            ),
        ])

        PrivatePaykitService.setProfileRecoveryPending(false)
        await service.closeAndClear(markProfileRecoveryPending: true)
        defer { PrivatePaykitService.setProfileRecoveryPending(false) }

        XCTAssertTrue(PrivatePaykitService.isProfileRecoveryPending)
    }

    func testMarkProfileRecoveryPendingUsesPrivateContactStateWhenContactCleanupDefers() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: [:],
                linkCompletedAt: 123,
                handshakeUpdatedAt: nil,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil
            ),
        ])

        PrivatePaykitService.setProfileRecoveryPending(false)
        PrivatePaykitService.setContactSharingCleanupPending(false)
        await service.markProfileRecoveryPendingIfNeeded()
        await service.pruneUnsavedContactState(savedPublicKeys: [])
        defer {
            PrivatePaykitService.setProfileRecoveryPending(false)
            PrivatePaykitService.setContactSharingCleanupPending(false)
        }

        XCTAssertTrue(PrivatePaykitService.isProfileRecoveryPending)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey))
        let snapshot = await service.backupSnapshot()?[publicKey]
        XCTAssertEqual(snapshot?.linkCompletedAt, 123)
    }

    func testProfileRecoveryPurgeFailureKeepsMarkerPending() async {
        let service = PrivatePaykitService()

        PrivatePaykitService.setProfileRecoveryPending(false)
        let error = await service.handleProfileRecoveryPurgeFailure(requireImmediatePublication: false)
        defer { PrivatePaykitService.setProfileRecoveryPending(false) }

        XCTAssertNil(error)
        XCTAssertTrue(PrivatePaykitService.isProfileRecoveryPending)
    }

    func testProfileRecoveryPurgeFailureFailsImmediateMode() async {
        let service = PrivatePaykitService()

        PrivatePaykitService.setProfileRecoveryPending(false)
        let error = await service.handleProfileRecoveryPurgeFailure(requireImmediatePublication: true)
        defer { PrivatePaykitService.setProfileRecoveryPending(false) }

        guard case .privateUnavailable = error as? PrivatePaykitError else {
            return XCTFail("Expected privateUnavailable")
        }
        XCTAssertTrue(PrivatePaykitService.isProfileRecoveryPending)
    }

    func testProfileRecoveryStateClearsOldEndpointMetadata() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        let remoteEndpoints = [
            PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue: #"{"value":"bcrt1qcached"}"#,
        ]
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: remoteEndpoints,
                linkCompletedAt: 123,
                handshakeUpdatedAt: 100,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil
            ),
        ])

        await service.markContactForProfileRecovery(publicKey, startedAt: 456)
        let snapshot = await service.backupSnapshot()?[publicKey]

        XCTAssertEqual(snapshot?.recoveryStartedAt, 456)
        XCTAssertNil(snapshot?.linkSnapshotHex)
        XCTAssertNil(snapshot?.handshakeSnapshotHex)
        XCTAssertEqual(snapshot?.remoteEndpoints, [:])
        XCTAssertNil(snapshot?.linkCompletedAt)
        XCTAssertNil(snapshot?.handshakeUpdatedAt)
    }

    func testPrivatePaymentDefersPublicFallbackAfterRecoveryLinkCompletesWithoutEndpoints() async {
        let service = PrivatePaykitService()
        var contactState = PrivatePaykitService.ContactState()
        contactState.linkCompletedAt = 123
        contactState.lastCompletedRecoveryAttemptId = "attempt"
        contactState.awaitingRecoveredRemoteEndpoints = true

        let shouldDefer = await service.shouldDeferPublicFallbackForPrivateRecovery(contactState: contactState)

        XCTAssertTrue(shouldDefer)
    }

    func testPrivatePaymentDoesNotDeferPublicFallbackForConsumedRecoveredEndpoints() async {
        let service = PrivatePaykitService()
        var contactState = PrivatePaykitService.ContactState()
        contactState.linkCompletedAt = 123
        contactState.lastCompletedRecoveryAttemptId = "attempt"

        let shouldDefer = await service.shouldDeferPublicFallbackForPrivateRecovery(contactState: contactState)

        XCTAssertFalse(shouldDefer)
    }

    func testPrivatePaymentDoesNotDeferPublicFallbackForPendingNonRecoveryHandshake() async {
        let service = PrivatePaykitService()
        var contactState = PrivatePaykitService.ContactState()
        contactState.handshakeSnapshotHex = "pending-handshake"

        let shouldDefer = await service.shouldDeferPublicFallbackForPrivateRecovery(contactState: contactState)

        XCTAssertFalse(shouldDefer)
    }

    func testPrivatePaymentKeepsAwaitingRecoveredEndpointsUntilRemoteEntriesArrive() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: [:],
                linkCompletedAt: 123,
                handshakeUpdatedAt: nil,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil,
                awaitingRecoveredRemoteEndpoints: true
            ),
        ])

        let snapshot = await service.backupSnapshot()?[publicKey]
        let shouldDefer = await service.shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)

        XCTAssertTrue(shouldDefer)
        XCTAssertEqual(snapshot?.awaitingRecoveredRemoteEndpoints, true)
    }

    func testPrivatePaymentKeepsAwaitingRecoveredEndpointsForTombstones() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: [:],
                linkCompletedAt: 123,
                handshakeUpdatedAt: nil,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil,
                awaitingRecoveredRemoteEndpoints: true
            ),
        ])

        await service.cacheRemoteEndpoints(
            [
                FfiPaymentEntry(
                    methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                    endpointData: PrivatePaykitService.privateEndpointRemovalPayload
                ),
                FfiPaymentEntry(
                    methodId: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
                    endpointData: PrivatePaykitService.privateEndpointRemovalPayload
                ),
            ],
            publicKey: publicKey
        )

        let result = await service.cachedPrivatePaymentResult(publicKey: publicKey)
        let snapshot = await service.backupSnapshot()?[publicKey]
        let shouldDefer = await service.shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)

        guard case .notOpened = result else {
            return XCTFail("Expected tombstones to be non-payable")
        }
        XCTAssertTrue(shouldDefer)
        XCTAssertEqual(snapshot?.awaitingRecoveredRemoteEndpoints, true)
    }

    func testPrivatePaymentClearingAwaitingRecoveredEndpointsMarksWalletBackupChanged() async {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        await service.restoreBackup([
            publicKey: PrivatePaykitContactLinkBackupV1(
                publicKey: publicKey,
                linkSnapshotHex: nil,
                handshakeSnapshotHex: nil,
                remoteEndpoints: [:],
                linkCompletedAt: 123,
                handshakeUpdatedAt: nil,
                recoveryStartedAt: nil,
                mainRecoveryAttemptId: nil,
                responderRecoveryAttemptId: nil,
                awaitingRecoveredRemoteEndpoints: true
            ),
        ])

        let backupChanged = expectation(description: "private Paykit recovery marker clear marks wallet backup data changed")
        let cancellable = PrivatePaykitService.walletBackupDataChangedPublisher.sink {
            backupChanged.fulfill()
        }

        await service.clearAwaitingRecoveredRemoteEndpoints(publicKey: publicKey)
        await fulfillment(of: [backupChanged], timeout: 1)

        let snapshot = await service.backupSnapshot()?[publicKey]
        XCTAssertNil(snapshot?.awaitingRecoveredRemoteEndpoints)
        _ = cancellable
    }

    func testPrivatePaymentDoesNotRetryGenericPrivateUnavailableBeforePublicFallback() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        let result: Result<PublicPaykitPaymentLaunchResult, Error> = .failure(PrivatePaykitError.privateUnavailable)

        let shouldRetry = try await service.shouldRetryPrivatePaymentBeforePublicFallback(
            publicKey: publicKey,
            result: result,
            shouldDeferPublicFallback: false
        )

        XCTAssertFalse(shouldRetry)
    }

    func testPrivatePaymentRetriesPrivateUnavailableDuringRecovery() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubkycytinw71a3ge1esmzj5e53hsr3jtj6t4pogpgr6k75w9mzmyokzo"
        let result: Result<PublicPaykitPaymentLaunchResult, Error> = .failure(PrivatePaykitError.privateUnavailable)

        let shouldRetry = try await service.shouldRetryPrivatePaymentBeforePublicFallback(
            publicKey: publicKey,
            result: result,
            shouldDeferPublicFallback: true
        )

        XCTAssertTrue(shouldRetry)
    }
}
