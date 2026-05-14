@testable import Bitkit
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

    func testStaleLinkFailureClassificationUsesTypedPaykitErrors() async {
        let service = PrivatePaykitService()
        let noiseFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Transport(reason: "noise state decrypt failed"))
        let linkHandleFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Validation(reason: "Unknown encrypted-link handle: 123"))
        let networkFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Transport(reason: "connection timed out"))
        let sessionFailure = await service.shouldCountAsStaleLinkFailure(PaykitFfiError.Session(reason: "No active session"))

        XCTAssertTrue(noiseFailure)
        XCTAssertTrue(linkHandleFailure)
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
                    responderRecoveryAttemptId: "responder-attempt"
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
}
