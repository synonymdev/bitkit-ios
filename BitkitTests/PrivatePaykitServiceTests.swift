@testable import Bitkit
import XCTest

final class PrivatePaykitServiceTests: XCTestCase {
    func testReceiverNoiseDerivationMatchesCrossPlatformVector() {
        let seed = (
            "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e534955" +
                "31f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        ).hexaData

        let key = PaykitReceiverNoiseKeyDerivation.derive(
            seed: seed,
            network: "bitcoin",
            receiverPath: PaykitReceiverPath.wallet
        )

        XCTAssertEqual(key.hex, "500f4799bbb2d02103e3b74b365ddb478a3187333c053fa9eb62f4052ba6a327")
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

    func testPrivateReservationAttributionMatchesSdkPublicationMetadata() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubkycontact"
        await service.setTestLocalInvoice(
            PrivatePaykitService.StoredInvoice(
                bolt11: "lnbc1private",
                paymentHash: "payment-hash",
                expiresAt: 123
            ),
            publicKey: publicKey
        )

        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningBolt11,
            value: "lnbc1private",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"lnbc1private"}"#
        )

        let reservations = await service.reservations(
            from: [endpoint],
            publicKey: publicKey,
            receiverPath: PaykitReceiverPath.wallet
        )
        XCTAssertEqual(reservations.count, 1)
        let reservation = try XCTUnwrap(reservations.first)
        let attribution = reservation.attribution

        XCTAssertEqual(attribution["type"], "private_paykit")
        XCTAssertEqual(attribution["counterparty"], publicKey)
        XCTAssertEqual(attribution["receiver_path"], PaykitReceiverPath.wallet)
        XCTAssertEqual(attribution["payment_hash"], "payment-hash")
    }

    func testPrivateReservationIdChangesWhenEndpointPayloadChanges() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubkycontact"
        let firstEndpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh,
            value: "bcrt1qfirst",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"bcrt1qfirst"}"#
        )
        let secondEndpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh,
            value: "bcrt1qsecond",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"bcrt1qsecond"}"#
        )

        let firstReservations = await service.reservations(
            from: [firstEndpoint],
            publicKey: publicKey,
            receiverPath: PaykitReceiverPath.wallet
        )
        let repeatedReservations = await service.reservations(
            from: [firstEndpoint],
            publicKey: publicKey,
            receiverPath: PaykitReceiverPath.wallet
        )
        let secondReservations = await service.reservations(
            from: [secondEndpoint],
            publicKey: publicKey,
            receiverPath: PaykitReceiverPath.wallet
        )
        let serverReservations = await service.reservations(
            from: [firstEndpoint],
            publicKey: publicKey,
            receiverPath: PaykitReceiverPath.server
        )

        let firstReservation = try XCTUnwrap(firstReservations.first)
        let repeatedReservation = try XCTUnwrap(repeatedReservations.first)
        let secondReservation = try XCTUnwrap(secondReservations.first)
        let serverReservation = try XCTUnwrap(serverReservations.first)

        XCTAssertEqual(firstReservation.reservationId, repeatedReservation.reservationId)
        XCTAssertNotEqual(firstReservation.reservationId, secondReservation.reservationId)
        XCTAssertNotEqual(firstReservation.reservationId, serverReservation.reservationId)
        XCTAssertEqual(serverReservation.attribution["receiver_path"], PaykitReceiverPath.server)
        XCTAssertTrue(firstReservation.reservationId.hasPrefix("\(publicKey):\(PaykitReceiverPath.wallet):\(firstEndpoint.methodId.rawValue):"))
        XCTAssertLessThanOrEqual(firstReservation.reservationId.count, 128)
    }

    func testWalletBackupDecodesExistingPayloadWithoutPrivatePaykitFields() throws {
        let data = #"{"version":1,"createdAt":123,"transfers":[]}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertTrue(payload.transfers.isEmpty)
        XCTAssertNil(payload.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertNil(payload.paykitSdkBackupState)
        XCTAssertNil(payload.watchOnlyAccounts)
        XCTAssertNil(payload.watchOnlyAccountAllocationState)
    }

    func testWalletBackupRoundTripsPrivateReservationCeilingAndSdkState() throws {
        let backup = WalletBackupV1(
            version: 1,
            createdAt: 123,
            transfers: [],
            privatePaykitHighestReservedReceiveIndexByAddressType: ["nativeSegwit": 5],
            paykitSdkBackupState: "AQID",
            watchOnlyAccounts: nil,
            watchOnlyAccountAllocationState: nil
        )

        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertEqual(decoded.version, backup.version)
        XCTAssertEqual(decoded.createdAt, backup.createdAt)
        XCTAssertTrue(decoded.transfers.isEmpty)
        XCTAssertEqual(decoded.privatePaykitHighestReservedReceiveIndexByAddressType, backup.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertEqual(decoded.paykitSdkBackupState, backup.paykitSdkBackupState)
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

    func testPrivatePaykitStateStoresOnlyAppOwnedAttributionState() throws {
        let publicKey = "pubkycontact"
        var contactState = PrivatePaykitService.ContactState()
        contactState.cachedResolvedEndpoints = [
            PrivatePaykitService.StoredPaymentEntry(
                methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                endpointData: #"{"value":"lnbc1cached"}"#
            ),
        ]
        contactState.localInvoicesByReceiverPath[PaykitReceiverPath.wallet] = PrivatePaykitService.StoredInvoice(
            bolt11: "lnbc1local",
            paymentHash: "hash",
            expiresAt: 123
        )
        contactState.receivedInvoicePaymentHashes = ["received-hash"]
        contactState.publishedPrivatePaymentReceiverPaths = [PaykitReceiverPath.wallet]

        let state = PrivatePaykitService.PrivatePaykitState(contacts: [publicKey: contactState])
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("lnbc1cached"))
        XCTAssertTrue(json.contains("lnbc1local"))
        XCTAssertTrue(json.contains("received-hash"))
        let decoded = try JSONDecoder().decode(PrivatePaykitService.PrivatePaykitState.self, from: data)
        let decodedContact = try XCTUnwrap(decoded.contacts[publicKey])
        XCTAssertEqual(decodedContact.cachedResolvedEndpoints.first?.methodId, PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue)
        XCTAssertEqual(decodedContact.cachedResolvedEndpoints.first?.endpointData, #"{"value":"lnbc1cached"}"#)
        XCTAssertEqual(decodedContact.localInvoicesByReceiverPath[PaykitReceiverPath.wallet]?.bolt11, "lnbc1local")
        XCTAssertEqual(decodedContact.localInvoicesByReceiverPath[PaykitReceiverPath.wallet]?.paymentHash, "hash")
        XCTAssertEqual(decodedContact.localInvoicesByReceiverPath[PaykitReceiverPath.wallet]?.expiresAt, 123)
        XCTAssertEqual(decodedContact.receivedInvoicePaymentHashes, ["received-hash"])
        XCTAssertEqual(decodedContact.publishedPrivatePaymentReceiverPaths, [PaykitReceiverPath.wallet])
    }

    func testConsumingPrivatePaymentListClearsEndpointsAndRejectsSameVersionForPair() async throws {
        let defaults = UserDefaults.standard
        let previousState = defaults.data(forKey: PrivatePaykitService.cacheStateKey)
        defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        defer {
            if let previousState {
                defaults.set(previousState, forKey: PrivatePaykitService.cacheStateKey)
            } else {
                defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
            }
        }

        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningLnurl,
            value: "lnurl1private",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"lnurl1private"}"#
        )
        let context = PrivatePaykitPaymentContext(receiverPath: PaykitReceiverPath.wallet, paymentListVersion: 7)

        await service.cacheResolvedEndpoints([endpoint], publicKey: publicKey)
        try await service.consumePrivatePaymentList(publicKey: publicKey, context: context)

        let contactState = await service.testContactState(publicKey: publicKey)
        XCTAssertTrue(contactState?.cachedResolvedEndpoints.isEmpty == true)
        XCTAssertEqual(contactState?.consumedPrivatePaymentListVersionsByReceiverPath[PaykitReceiverPath.wallet], 7)

        do {
            try await service.consumePrivatePaymentList(publicKey: publicKey, context: context)
            XCTFail("Expected the private payment list to be consumed only once")
        } catch PrivatePaykitError.paymentListAlreadyConsumed {
            // Expected.
        }
    }

    func testClearingContactStatePreservesConsumedPrivatePaymentListVersions() async throws {
        let defaults = UserDefaults.standard
        let previousState = defaults.data(forKey: PrivatePaykitService.cacheStateKey)
        defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        defer {
            if let previousState {
                defaults.set(previousState, forKey: PrivatePaykitService.cacheStateKey)
            } else {
                defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
            }
        }

        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningLnurl,
            value: "lnurl1private",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"lnurl1private"}"#
        )
        let context = PrivatePaykitPaymentContext(receiverPath: PaykitReceiverPath.server, paymentListVersion: 9)

        await service.cacheResolvedEndpoints([endpoint], publicKey: publicKey)
        try await service.consumePrivatePaymentList(publicKey: publicKey, context: context)
        await service.clearContactState(publicKey: publicKey)

        let contactState = await service.testContactState(publicKey: publicKey)
        XCTAssertEqual(contactState?.consumedPrivatePaymentListVersionsByReceiverPath, [PaykitReceiverPath.server: 9])
        XCTAssertFalse(contactState?.hasContactOwnedCacheState == true)
    }

    func testPrivatePaymentRecoveryUsesRequestedReceiverPath() async {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        await service.schedulePrivatePaymentRecovery(for: publicKey, receiverPath: PaykitReceiverPath.server)

        let retryKeys = await service.testPendingMessageDrainRetryKeys()
        XCTAssertEqual(
            retryKeys,
            [PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: PaykitReceiverPath.server)]
        )
        await service.clearTestPendingMessageDrainRetries()
    }
}

private extension PrivatePaykitService {
    func setTestLocalInvoice(_ invoice: StoredInvoice, publicKey: String) {
        state.contacts[publicKey] = ContactState()
        state.contacts[publicKey]?.localInvoicesByReceiverPath[PaykitReceiverPath.wallet] = invoice
    }

    func testContactState(publicKey: String) -> ContactState? {
        state.contacts[publicKey]
    }

    func testPendingMessageDrainRetryKeys() -> Set<PrivateMessageDrainRetryKey> {
        pendingMessageDrainRetryKeys
    }

    func clearTestPendingMessageDrainRetries() {
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetryKeys.removeAll()
    }
}
