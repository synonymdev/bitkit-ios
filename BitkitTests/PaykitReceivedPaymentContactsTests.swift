@testable import Bitkit
import BitkitCore
import Combine
import Foundation
import Paykit
import XCTest

final class PaykitReceivedPaymentContactsTests: XCTestCase {
    private let alice = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    private let bob = "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o"
    private let receivingAddress = "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"
    private let otherAddress = "bcrt1qpsps9chsjnnd3veems9phzlvw42em682rsj8hh"

    func testReservationOnlyAttributesLiveAndHistory() async throws {
        try await assertAttribution(
            contacts: PaykitReceivedPaymentContacts(), reservations: [receivingAddress: alice], expected: alice
        )
    }

    func testRequestAddressNormalizationPreservesValidationAndAmbiguity() async throws {
        let uppercase = receivingAddress.uppercased()
        try await assertAttribution(contacts: contacts(address: uppercase, counterparty: alice), reservations: [:], expected: alice)

        for mixedCase in ["B" + receivingAddress.dropFirst(), "b" + uppercase.dropFirst()] {
            XCTAssertTrue(try contacts(address: mixedCase, counterparty: alice).isEmpty)
        }

        let legacy = "n31ZLqqyfoYu4fjd16u7ZQaSqgGfrmw8wC"
        let legacyContacts = try PaykitReceivedPaymentContacts(
            records: [record(address: legacy, counterparty: alice, identifier: "btc-regtest-p2pkh")], network: .regtest
        )
        XCTAssertEqual(legacyContacts.contact(onchainAddresses: [legacy]), alice)
        XCTAssertNil(legacyContacts.contact(onchainAddresses: [legacy.lowercased()]))

        let ambiguous = try PaykitReceivedPaymentContacts(
            records: [record(address: uppercase, counterparty: alice), record(address: receivingAddress, counterparty: bob)],
            network: .regtest
        )
        try await assertAttribution(contacts: ambiguous, reservations: [receivingAddress: alice], expected: nil)
    }

    func testConflictingRequestsAndReservationsRejectLiveAndHistoryAttribution() async throws {
        let receivingRequest = try contacts(address: receivingAddress, counterparty: alice)
        let otherRequest = try contacts(address: otherAddress, counterparty: bob)
        let cases = [
            ("Receiving reservation, request on other output", otherRequest, [receivingAddress: alice]),
            ("Reservations on both outputs", PaykitReceivedPaymentContacts(), [receivingAddress: alice, otherAddress: bob]),
            ("Receiving request, reservation on other output", receivingRequest, [otherAddress: bob]),
            ("Request and reservation on same output", receivingRequest, [receivingAddress: bob]),
        ]
        for (scenario, contacts, reservations) in cases {
            try await assertAttribution(contacts: contacts, reservations: reservations, expected: nil, message: scenario)
        }
    }

    func testSameContactAcrossRequestAndReservationsIsUnambiguous() async throws {
        try await assertAttribution(
            contacts: contacts(address: otherAddress, counterparty: alice),
            reservations: [receivingAddress: String(alice.dropFirst(5)), otherAddress: alice], expected: alice
        )
    }

    func testOtherOutputNeverSuppliesPositiveAttribution() async throws {
        try await assertAttribution(
            contacts: contacts(address: otherAddress, counterparty: alice),
            reservations: [otherAddress: alice], expected: nil
        )
    }

    func testReceivingAddressMustBePresentInOutputs() async throws {
        let contacts = try contacts(address: receivingAddress, counterparty: alice)
        let combined = await contacts.includingReservations(for: [otherAddress]) { _ in self.alice }
        XCTAssertNil(combined.contact(receivingAddress: receivingAddress, outputAddresses: [otherAddress]))
        XCTAssertNil(combined.attributing(payment(), outputAddresses: [otherAddress]))
    }

    func testAmbiguousRequestIsNotHiddenByMatchingReservation() async throws {
        let contacts = try PaykitReceivedPaymentContacts(
            records: [record(address: receivingAddress, counterparty: alice), record(address: receivingAddress, counterparty: bob)],
            network: .regtest
        )
        try await assertAttribution(contacts: contacts, reservations: [receivingAddress: alice], expected: nil)
    }

    func testAttributionPreservesExistingContactAndRejectsSentPayments() async {
        let combined = await PaykitReceivedPaymentContacts().includingReservations(for: [receivingAddress]) { _ in self.alice }
        XCTAssertNil(combined.attributing(payment(contact: bob), outputAddresses: [receivingAddress]))
        XCTAssertNil(combined.attributing(payment(txType: .sent), outputAddresses: [receivingAddress]))
    }

    func testCompletedScanSkipsAllWorkWhenInputsAreUnchanged() async {
        let changes = PassthroughSubject<Void, Never>()
        let cache = PaykitReceivedPaymentBackfillCache(activityChanges: changes.eraseToAnyPublisher())
        let contacts = PaykitReceivedPaymentContacts()
        var scans = 0
        for _ in 0 ..< 2 {
            await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0) {
                scans += 1
                return true
            }
        }
        XCTAssertEqual(scans, 1, "Skip the entire scan, including transaction-detail and reservation lookups")
    }

    func testActivityChangesInvalidateCompletedAndInFlightScans() async {
        let changes = PassthroughSubject<Void, Never>()
        let cache = PaykitReceivedPaymentBackfillCache(activityChanges: changes.eraseToAnyPublisher())
        let contacts = PaykitReceivedPaymentContacts()
        var scans = 0
        await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0) {
            scans += 1
            return true
        }
        changes.send()
        await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0) {
            scans += 1
            changes.send()
            return true
        }
        await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0) {
            scans += 1
            return true
        }
        XCTAssertEqual(scans, 3)
    }

    func testContactIdentityAndReservationChangesRescan() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let cache = PaykitReceivedPaymentBackfillCache(activityChanges: changes.eraseToAnyPublisher())
        let empty = PaykitReceivedPaymentContacts()
        let contacts = try contacts(address: receivingAddress, counterparty: alice)
        var scans = 0
        let scan = {
            scans += 1
            return true
        }
        await cache.scanIfNeeded(identity: alice, contacts: empty, reservationRevision: 0, scan: scan)
        await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0, scan: scan)
        await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 1, scan: scan)
        await cache.scanIfNeeded(identity: bob, contacts: contacts, reservationRevision: 1, scan: scan)
        cache.invalidate()
        await cache.scanIfNeeded(identity: bob, contacts: contacts, reservationRevision: 1, scan: scan)
        XCTAssertEqual(scans, 5)
    }

    func testBackfillRetriesMissingTransactionDetailsPersistsContactAndSkipsCompletedScan() async throws {
        let service = Bitkit.CoreService.shared.activity
        let testDbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaykitReceivedPaymentContactsTests-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: testDbPath, withIntermediateDirectories: true)
        addTeardownBlock {
            await self.drainCoreServiceQueue()
            await self.repointCoreToAppStorage()
            try? FileManager.default.removeItem(atPath: testDbPath)
        }
        await drainCoreServiceQueue()
        _ = try await Bitkit.ServiceQueue.background(.core) { try initDb(basePath: testDbPath) }

        let reservations = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults())
        let contacts = try contacts(address: receivingAddress, counterparty: alice)
        let activity = payment()
        try await service.insert(activity)
        let inserted = try await service.getActivity(id: activity.activityId)
        let baseline = try XCTUnwrap(inserted)
        guard case let .onchain(baselinePayment) = baseline else { return XCTFail("Expected the inserted received payment") }
        let cache = PaykitReceivedPaymentBackfillCache(activityChanges: service.activitiesChangedPublisher)
        let missingDetails = try await service.getTransactionDetails(txid: "tx-received")
        XCTAssertNil(missingDetails)

        try await service.backfillReceivedPaykitContacts(contacts, identity: alice, cache: cache, reservations: reservations) { true }
        let unattributed = try await service.getActivity(id: activity.activityId)
        XCTAssertEqual(unattributed, baseline, "Missing details must leave the received payment unchanged")

        let details = BitkitCore.TransactionDetails(
            walletId: WalletScope.default, txId: "tx-received", amountSats: 15000, inputs: [],
            outputs: [TxOutput(scriptpubkey: "", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: receivingAddress, value: 15000, n: 0)]
        )
        // No activity notification: incomplete scans must retry even when all cache inputs stay unchanged.
        try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [details]) }
        try await service.backfillReceivedPaykitContacts(contacts, identity: alice, cache: cache, reservations: reservations) { true }
        let persisted = try await service.getActivity(id: activity.activityId)
        guard case let .onchain(payment) = persisted else { return XCTFail("Expected the stored received payment") }
        XCTAssertEqual(payment.contact, alice, "Retry must persist the attributed contact in BitkitCore")
        XCTAssertEqual(payment.value, baselinePayment.value)
        XCTAssertEqual(payment.seenAt, baselinePayment.seenAt)

        // The write publishes an activity change; complete one scan at that new revision before checking the skip.
        try await service.backfillReceivedPaykitContacts(contacts, identity: alice, cache: cache, reservations: reservations) { true }
        try await service.backfillReceivedPaykitContacts(contacts, identity: alice, cache: cache, reservations: reservations) {
            XCTFail("An unchanged completed backfill must skip the scan")
            return false
        }
        let afterSkippedScan = try await service.getActivity(id: activity.activityId)
        XCTAssertEqual(afterSkippedScan, persisted)

        defer { service.setContactDetached(false, activityId: activity.activityId, walletId: WalletScope.default) }
        try await service.setContact(nil, forActivity: activity.activityId)
        try await service.backfillReceivedPaykitContacts(contacts, identity: alice, cache: cache, reservations: reservations) { true }
        let detached = try await service.getActivity(id: activity.activityId)
        guard case let .onchain(detachedPayment) = detached else { return XCTFail("Expected the detached payment") }
        XCTAssertNil(detachedPayment.contact)
        try await service.setContact(bob, forActivity: activity.activityId)
        XCTAssertFalse(service.isContactDetached(activityId: activity.activityId, walletId: WalletScope.default))
    }

    func testUnavailableReservationsCannotCacheNegativeMatch() async {
        let changes = PassthroughSubject<Void, Never>()
        let cache = PaykitReceivedPaymentBackfillCache(activityChanges: changes.eraseToAnyPublisher())
        let contacts = PaykitReceivedPaymentContacts()
        do {
            try await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0) {
                _ = try await contacts.includingReservations(for: [self.receivingAddress]) { _ in
                    throw NSError(domain: "reservation-derivation", code: 1)
                }
                return true
            }
            XCTFail("Expected reservation lookup to fail")
        } catch {}
        var retried = false
        await cache.scanIfNeeded(identity: alice, contacts: contacts, reservationRevision: 0) {
            retried = true
            let combined = await contacts.includingReservations(for: [self.receivingAddress]) { _ in self.alice }
            XCTAssertEqual(combined.contact(receivingAddress: self.receivingAddress, outputAddresses: [self.receivingAddress]), self.alice)
            return true
        }
        XCTAssertTrue(retried)
    }

    func testReservationRevisionChangesOnRestoreAndClear() async throws {
        let suiteName = "PaykitReceivedPaymentContactsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PrivatePaykitAddressReservationStore(defaults: defaults)
        let initial = await store.attributionRevision
        await store.restoreBackup(nil)
        let restored = await store.attributionRevision
        await store.clear()
        let cleared = await store.attributionRevision
        XCTAssertGreaterThan(restored, initial)
        XCTAssertGreaterThan(cleared, restored)
    }

    private func assertAttribution(
        contacts: PaykitReceivedPaymentContacts,
        reservations: [String: String],
        expected: String?,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let outputs = [otherAddress, receivingAddress, receivingAddress]
        let combined = await contacts.includingReservations(for: outputs) { reservations[$0] }
        XCTAssertEqual(combined.contact(receivingAddress: receivingAddress, outputAddresses: outputs), expected, message, file: file, line: line)
        let attributed = combined.attributing(payment(), outputAddresses: outputs)
        if let expected {
            guard case let .onchain(updated) = attributed else { return XCTFail("Expected attributed history", file: file, line: line) }
            XCTAssertEqual(updated.contact, expected, file: file, line: line)
            XCTAssertEqual(updated.value, 15000, file: file, line: line)
            XCTAssertEqual(updated.seenAt, 125, file: file, line: line)
        } else {
            XCTAssertNil(attributed, message, file: file, line: line)
        }
    }

    private func payment(id: String = "received", contact: String? = nil, txType: PaymentType = .received) -> Activity {
        .onchain(OnchainActivity(
            walletId: WalletScope.default, id: id, txType: txType, txId: "tx-\(id)", value: 15000,
            fee: 0, feeRate: 0, address: receivingAddress, confirmed: true, timestamp: 123,
            isBoosted: false, boostTxIds: [], isTransfer: false, doesExist: true, confirmTimestamp: 124,
            channelId: nil, transferTxId: nil, contact: contact, createdAt: 123, updatedAt: 124, seenAt: 125
        ))
    }

    private func contacts(address: String, counterparty: String) throws -> PaykitReceivedPaymentContacts {
        try PaykitReceivedPaymentContacts(records: [record(address: address, counterparty: counterparty)], network: .regtest)
    }

    private func record(address: String, counterparty: String, identifier: String = "btc-regtest-p2wpkh") throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty, paymentRequestId: "550e8400-e29b-41d4-a716-446655440000", localRole: .payee,
            state: .proposed, proposalStreamItemId: 1, proposalOutboundMessageId: nil, proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000", proposalAppId: "paykit-server", payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: "btc"), paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil, recurrence: nil, acceptedPaymentEndpointIdentifiers: [identifier],
                paymentEndpoints: [identifier: PublicPaykitService.serializePayload(value: address)],
                requiredAppId: nil, conversion: nil, paymentDeadline: nil, metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil, acceptedOutboundStatus: nil, rejectedEventId: nil, rejectedOutboundStatus: nil,
            canceledEventId: nil, canceledOutboundStatus: nil, conversionQuotes: [], paymentProofs: [],
            lastStreamItemId: 1, lastOutboundMessageId: nil, lastOutboundStatus: nil, lastEventAt: "2027-01-15T08:00:00Z", invalidReason: nil
        )
    }
}
