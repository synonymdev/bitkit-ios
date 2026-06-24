@testable import Bitkit
import XCTest

final class PrivatePaykitServiceTests: XCTestCase {
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

        let reservations = await service.reservations(from: [endpoint], publicKey: publicKey)
        XCTAssertEqual(reservations.count, 1)
        let reservation = try XCTUnwrap(reservations.first)
        let attribution = reservation.attribution

        XCTAssertEqual(attribution["type"], "private_paykit")
        XCTAssertEqual(attribution["counterparty"], publicKey)
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

        let firstReservations = await service.reservations(from: [firstEndpoint], publicKey: publicKey)
        let repeatedReservations = await service.reservations(from: [firstEndpoint], publicKey: publicKey)
        let secondReservations = await service.reservations(from: [secondEndpoint], publicKey: publicKey)

        let firstReservation = try XCTUnwrap(firstReservations.first)
        let repeatedReservation = try XCTUnwrap(repeatedReservations.first)
        let secondReservation = try XCTUnwrap(secondReservations.first)

        XCTAssertEqual(firstReservation.reservationId, repeatedReservation.reservationId)
        XCTAssertNotEqual(firstReservation.reservationId, secondReservation.reservationId)
        XCTAssertTrue(firstReservation.reservationId.hasPrefix("\(publicKey):\(firstEndpoint.methodId.rawValue):"))
        XCTAssertLessThanOrEqual(firstReservation.reservationId.count, 128)
    }

    func testWalletBackupDecodesExistingPayloadWithoutPrivatePaykitFields() throws {
        let data = #"{"version":1,"createdAt":123,"transfers":[]}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertTrue(payload.transfers.isEmpty)
        XCTAssertNil(payload.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertNil(payload.paykitSdkBackupState)
    }

    func testWalletBackupRoundTripsPrivateReservationCeilingAndSdkState() throws {
        let backup = WalletBackupV1(
            version: 1,
            createdAt: 123,
            transfers: [],
            privatePaykitHighestReservedReceiveIndexByAddressType: ["nativeSegwit": 5],
            paykitSdkBackupState: "AQID"
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
        contactState.localInvoice = PrivatePaykitService.StoredInvoice(bolt11: "lnbc1local", paymentHash: "hash", expiresAt: 123)
        contactState.receivedInvoicePaymentHashes = ["received-hash"]
        contactState.hasPublishedPrivatePaymentList = true

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
        XCTAssertEqual(decodedContact.localInvoice?.bolt11, "lnbc1local")
        XCTAssertEqual(decodedContact.localInvoice?.paymentHash, "hash")
        XCTAssertEqual(decodedContact.localInvoice?.expiresAt, 123)
        XCTAssertEqual(decodedContact.receivedInvoicePaymentHashes, ["received-hash"])
        XCTAssertTrue(decodedContact.hasPublishedPrivatePaymentList)
    }
}

private extension PrivatePaykitService {
    func setTestLocalInvoice(_ invoice: StoredInvoice, publicKey: String) {
        state.contacts[publicKey] = ContactState()
        state.contacts[publicKey]?.localInvoice = invoice
    }
}
