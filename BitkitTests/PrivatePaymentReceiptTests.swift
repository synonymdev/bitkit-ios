@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class PrivatePaymentReceiptTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivatePaymentReceiptTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        snapshotAppDefaultsDomain()
        _ = Bitkit.CoreService.shared
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        _ = try initDb(basePath: database.path)
    }

    override func tearDown() async throws {
        await drainCoreServiceQueue()
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(at: database)
        try await super.tearDown()
    }

    func testReceiptsCannotStartDuringReservedPersistedOrUnreadableWipe() async throws {
        for state in ["reserved", "persisted", "unreadable"] {
            let marker = database.appendingPathComponent("pending-\(state).json")
            let store = ProfileRemovalStore(url: marker)
            let admission = ProfileOperationAdmission(store: store)
            let scope = try admission.reserve(kind: .walletWipe, id: UUID())
            defer { admission.release(scope) }
            if state != "reserved" {
                try admission.persist(scope)
                admission.release(scope)
            }
            if state == "unreadable" {
                try Data("unreadable".utf8).write(to: marker)
            }
            let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
            activity.setPrivatePaykitContactResolvers(invoice: { _ in
                XCTFail("Rejected receipt reached invoice lookup")
                return nil
            }, onchainAddresses: { _, _ in
                XCTFail("Rejected receipt reached address lookup")
                return nil
            }, receiptOperation: { try await admission.withReceiptAttribution($0) })
            let hash = String(repeating: "a", count: 64)
            let payments = [
                invoicePayment(hash: hash),
                LDKNode.PaymentDetails(id: hash, kind: .onchain(txid: hash, status: .unconfirmed), amountMsat: 5_000_000,
                                       feePaidMsat: 0, direction: .inbound, status: .succeeded,
                                       latestUpdateTimestamp: UInt64(Date().timeIntervalSince1970)),
            ]
            for payment in payments {
                do {
                    try await activity.syncLdkNodePayments([payment])
                    XCTFail("Receipt started while wallet admission was closed: \(state)")
                } catch {
                    let underlying = (error as? Bitkit.AppError)?.underlyingError ?? error
                    XCTAssertTrue(underlying is ProfileRemovalStore.StoreError, "Unexpected error: \(error)")
                }
            }
            let details = LDKNode.TransactionDetails(amountSats: 5000, inputs: [], outputs: [])
            for confirmed in [false, true] {
                do {
                    if confirmed {
                        try await activity.handleOnchainTransactionConfirmed(txid: hash, details: details)
                    } else {
                        try await activity.handleOnchainTransactionReceived(txid: hash, details: details)
                    }
                    XCTFail("Rejected onchain event entered its storage path")
                } catch is ProfileRemovalStore.StoreError {}
            }
            let storedDetails = try await Bitkit.ServiceQueue.background(.core) {
                try BitkitCore.getTransactionDetails(walletId: WalletScope.default, txId: hash)
            }
            XCTAssertNil(storedDetails)
            if state == "reserved" {
                try await admission.drain(before: scope)
                try admission.persist(scope)
            }
            let rows = try await activity.get(walletId: WalletScope.default)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testPrivateInvoiceReceiptsDuringRemovalRetainTheirContact() async throws {
        let directory = database.appendingPathComponent("profile-removal")
        let admission = ProfileOperationAdmission(store: ProfileRemovalStore(url: directory.appendingPathComponent("pending.json")))
        let contact = "pubky" + String(repeating: "y", count: 52)
        let hashes = (0 ... 3).map { String(repeating: String($0), count: 64) }
        var state = PrivatePaykitService.ContactState()
        state.localInvoice = .init(bolt11: "fixture", paymentHash: hashes[0], expiresAt: Date().timeIntervalSince1970 + 3600)
        state.receivedInvoicePaymentHashes = Array(hashes.dropFirst())
        let encoded = try JSONEncoder().encode(PrivatePaykitService.PrivatePaykitState(contacts: [contact: state]))
        UserDefaults.standard.set(encoded, forKey: PrivatePaykitService.cacheStateKey)
        let privateService = PrivatePaykitService(profileAdmission: admission)
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
        activity.setPrivatePaykitContactResolvers(invoice: { hash in
            await privateService.contactPublicKeyForReceipt(paymentHash: hash)
        }, onchainAddresses: nil, receiptOperation: { operation in
            try await admission.withReceiptAttribution(operation)
        })
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let payments = hashes.map { hash in
            LDKNode.PaymentDetails(
                id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: nil),
                amountMsat: 5_000_000, feePaidMsat: 0, direction: .inbound, status: .succeeded,
                latestUpdateTimestamp: timestamp
            )
        }
        try await activity.syncLdkNodePayments([payments[1]])
        var rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        guard case let .lightning(baseline) = try XCTUnwrap(rows.first) else { return XCTFail("Missing baseline receipt") }
        XCTAssertEqual(baseline.contact, contact)

        let removal = try admission.reserve(kind: .removal, id: UUID(), expected: admission.snapshot())
        defer { admission.release(removal) }
        let hiddenLiveContact = await privateService.contactPublicKey(forPrivateInvoicePaymentHash: hashes[0])
        XCTAssertNil(hiddenLiveContact)
        try await activity.syncLdkNodePayments([payments[2]])
        try admission.persist(removal)
        try await activity.syncLdkNodePayments([payments[0], payments[3]])
        let retained = await privateService.state.contacts[contact]
        XCTAssertEqual(retained?.localInvoice?.paymentHash, hashes[0])
        XCTAssertEqual(retained?.receivedInvoicePaymentHashes, Array(hashes.dropFirst()))
        _ = try await privateService.closeAndClear()
        try admission.complete(removal)
        try await activity.syncLdkNodePayments(payments)
        rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        XCTAssertEqual(rows.count, 4)
        for case let .lightning(row) in rows {
            XCTAssertEqual(row.value, 5000)
            XCTAssertEqual(row.status, .succeeded)
            XCTAssertEqual(row.contact, contact, "Receipt \(row.id) lost its retained private-invoice association")
        }
    }

    func testReservedAddressReceiptsDuringRemovalRetainTheirContact() async throws {
        let suite = "PendingReceiptReservations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let contact = "pubky" + String(repeating: "y", count: 52)
        let original: [String: Any] = [
            "version": 1,
            "reservedReceiveIndexesByAddressType": ["nativeSegwit": [3, 7]],
            "contactAssignments": [contact: ["addressType": "nativeSegwit", "receiveIndex": 7]],
            "contactAssignmentHistory": [contact: [["addressType": "nativeSegwit", "receiveIndex": 3]]],
            "restoredReservedReceiveIndexCeilingsByAddressType": ["taproot": 12],
        ]
        try defaults.set(JSONSerialization.data(withJSONObject: original), forKey: PrivatePaykitAddressReservationStore.defaultsKey)
        let addresses = try nativeAddresses(directory: database.appendingPathComponent("node"))
        let reservations = PrivatePaykitAddressReservationStore(defaults: defaults, addressLookup: { type, index in
            XCTAssertEqual(type, .nativeSegwit)
            return try XCTUnwrap(addresses[index])
        })
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
        activity.setPrivatePaykitContactResolvers(invoice: nil, onchainAddresses: { address, outputs in
            let revision = await reservations.attributionRevision
            guard let contacts = try? await reservations.contactsForReceipt(
                PaykitReceivedPaymentContacts(), outputAddresses: outputs, expectedRevision: revision
            )
            else { return nil }
            return contacts.contact(receivingAddress: address, outputAddresses: outputs)
        }, receiptOperation: { operation in
            try await ProfileOperationAdmission.shared.withReceiptAttribution(operation)
        })
        let timestamp = UInt64(Date().timeIntervalSince1970)
        var payments: [LDKNode.PaymentDetails] = []
        func receive(_ number: Int, at index: UInt32) async throws {
            let txid = String(repeating: String(number), count: 64)
            let address = try XCTUnwrap(addresses[index])
            UserDefaults.standard.set(address, forKey: "onchainAddress")
            let details = BitkitCore.TransactionDetails(walletId: WalletScope.default, txId: txid, amountSats: 5000, inputs: [], outputs: [
                TxOutput(scriptpubkey: "", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: address, value: 5000, n: 0),
            ])
            try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [details]) }
            let payment = LDKNode.PaymentDetails(id: txid, kind: .onchain(txid: txid, status: .unconfirmed), amountMsat: 5_000_000,
                                                 feePaidMsat: 0, direction: .inbound, status: .succeeded, latestUpdateTimestamp: timestamp)
            payments.append(payment)
            try await activity.syncLdkNodePayments([payment])
        }
        try await receive(1, at: 7)
        let admission = ProfileOperationAdmission.shared
        let removal = try admission.reserve(kind: .removal, id: UUID(), expected: admission.snapshot())
        defer {
            _ = try? admission.complete(removal)
            admission.release(removal)
        }
        try await receive(2, at: 3)
        try admission.persist(removal)
        try await receive(3, at: 7)
        _ = try await reservations.clearContactAssignmentsForRemoval()
        try admission.complete(removal)
        try await activity.syncLdkNodePayments(payments)
        let rows = try await activity.get(filter: .onchain, walletId: WalletScope.default)
        XCTAssertEqual(rows.count, 3)
        for case let .onchain(row) in rows {
            XCTAssertEqual(row.value, 5000)
            XCTAssertEqual(row.contact, contact, "Receipt \(row.id) lost its retained reserved-address association")
        }
        let exclusions = await reservations.backupSnapshot()
        XCTAssertEqual(exclusions, ["nativeSegwit": 7, "taproot": 12])
    }

    func testCapturedInvoiceSurvivesProfileCompletionBeforeInsertion() async throws {
        let admission = ProfileOperationAdmission(store: ProfileRemovalStore(url: database.appendingPathComponent("pending.json")))
        let hash = String(repeating: "a", count: 64)
        let contact = "pubky" + String(repeating: "y", count: 52)
        let service = try invoiceService(hash: hash, contact: contact, admission: admission)
        let captured = expectation(description: "Invoice association captured")
        let gate = ReceiptGate()
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
        activity.setPrivatePaykitContactResolvers(invoice: { hash in
            let result = await service.contactPublicKeyForReceipt(paymentHash: hash)
            captured.fulfill()
            await gate.wait()
            return result
        }, onchainAddresses: nil, receiptOperation: { try await admission.withReceiptAttribution($0) })
        let syncing = Task { try await activity.syncLdkNodePayments([self.invoicePayment(hash: hash)]) }
        await fulfillment(of: [captured], timeout: 5)
        do {
            let removal = try admission.reserve(kind: .removal, id: UUID(), expected: admission.snapshot())
            defer { admission.release(removal) }
            try await admission.drain(before: removal)
            try admission.persist(removal)
            _ = try await service.closeAndClear()
            try admission.complete(removal)
        } catch {
            await gate.release()
            _ = try? await syncing.value
            throw error
        }
        let replacement = try admission.reserveSessionTransition()
        try await admission.drain(before: replacement)
        admission.release(replacement)
        await gate.release()
        try await syncing.value
        _ = try initDb(basePath: database.path)
        let rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        guard case let .lightning(row) = try XCTUnwrap(rows.first) else { return XCTFail("Missing receipt") }
        XCTAssertEqual(row.contact, contact)
        XCTAssertEqual(row.value, 5000)
        let cleared = await service.state.contacts
        XCTAssertTrue(cleared.isEmpty)
    }

    func testCancellationAndWipeRejectCapturedInvoiceAtBothDatabaseWritePaths() async throws {
        for wipe in [false, true] {
            for existingRow in [false, true] {
                let directory = database.appendingPathComponent(UUID().uuidString)
                let admission = ProfileOperationAdmission(store: ProfileRemovalStore(url: directory.appendingPathComponent("pending.json")))
                let hash = String(repeating: wipe ? (existingRow ? "d" : "c") : (existingRow ? "b" : "a"), count: 64)
                let contact = "pubky" + String(repeating: "y", count: 52)
                let service = try invoiceService(hash: hash, contact: contact, admission: admission)
                let captured = expectation(description: "Association captured before invalidation")
                let gate = ReceiptGate()
                let worker = ReceiptWorker()
                let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
                let payment = invoicePayment(hash: hash)
                if existingRow {
                    try await activity.syncLdkNodePayments([payment])
                }
                activity.setPrivatePaykitContactResolvers(invoice: { hash in
                    let result = await service.contactPublicKeyForReceipt(paymentHash: hash)
                    captured.fulfill()
                    await gate.wait()
                    return result
                }, onchainAddresses: nil, receiptOperation: { operation in
                    let task = Task { try await admission.withReceiptAttribution(operation) }
                    await worker.set(task)
                    try await task.value
                })
                let syncing = Task { try await activity.syncLdkNodePayments([payment]) }
                await fulfillment(of: [captured], timeout: 5)
                var wiping: ProfileOperationAdmission.Scope?
                if wipe {
                    let scope = try admission.reserve(kind: .walletWipe, id: UUID())
                    wiping = scope
                    XCTAssertThrowsError(try admission.persist(scope), "A captured receipt still owns its database write")
                } else {
                    await worker.cancel()
                }
                await gate.release()
                try await syncing.value
                let rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
                guard case let .lightning(row) = try XCTUnwrap(rows.first(where: { $0.activityId == hash }))
                else { return XCTFail("Missing receipt") }
                XCTAssertNil(row.contact, "Invalidated association entered the database")
                XCTAssertEqual(row.value, 5000)
                XCTAssertEqual(row.status, .succeeded)
                if let wiping {
                    defer { admission.release(wiping) }
                    try await admission.drain(before: wiping)
                    try admission.persist(wiping)
                    try await activity.removeAll()
                    _ = try await service.closeAndClear()
                    try admission.complete(wiping)
                    admission.release(wiping)
                    try await admission.withReceiptAttribution { canAttribute in XCTAssertTrue(canAttribute()) }
                    activity.setPrivatePaykitContactResolvers(invoice: { hash in
                        await service.contactPublicKeyForReceipt(paymentHash: hash)
                    }, onchainAddresses: nil, receiptOperation: { try await admission.withReceiptAttribution($0) })
                    try await activity.syncLdkNodePayments([payment])
                    let replacementRows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
                    guard case let .lightning(replacementRow) = try XCTUnwrap(replacementRows.first)
                    else { return XCTFail("Missing replacement receipt") }
                    XCTAssertNil(replacementRow.contact)
                }
            }
        }
    }

    func testAddressSnapshotPreservesContactAndAmbiguityAcrossProfileCleanup() async throws {
        try await addressReceiptCrossingCleanup(ambiguous: false, wipe: false)
        try await addressReceiptCrossingCleanup(ambiguous: true, wipe: false)
    }

    func testWipeDrainsCapturedAddressBeforeSameSeedWalletReplacement() async throws {
        try await addressReceiptCrossingCleanup(ambiguous: false, wipe: true)
    }

    private func addressReceiptCrossingCleanup(ambiguous: Bool, wipe: Bool) async throws {
        let directory = database.appendingPathComponent(UUID().uuidString)
        let addresses = try nativeAddresses(directory: directory.appendingPathComponent("original"))
        let suite = "ReceiptSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let contact = "pubky" + String(repeating: "y", count: 52)
        let other = ambiguous ? "pubky" + String(repeating: "b", count: 52) : contact
        let original: [String: Any] = [
            "version": 1,
            "reservedReceiveIndexesByAddressType": ["nativeSegwit": [3, 7]],
            "contactAssignments": [contact: ["addressType": "nativeSegwit", "receiveIndex": 7]],
            "contactAssignmentHistory": [other: [["addressType": "nativeSegwit", "receiveIndex": 3]]],
            "restoredReservedReceiveIndexCeilingsByAddressType": [:],
        ]
        try defaults.set(JSONSerialization.data(withJSONObject: original), forKey: PrivatePaykitAddressReservationStore.defaultsKey)
        let captured = expectation(description: "Assignment snapshot captured before derivation")
        let gate = ReceiptGate()
        let reservations = PrivatePaykitAddressReservationStore(defaults: defaults, addressLookup: { _, index in
            if await gate.shouldWait() {
                captured.fulfill()
                await gate.wait()
            }
            return try XCTUnwrap(addresses[index])
        })
        let admission = ProfileOperationAdmission.shared
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in nil })
        activity.setPrivatePaykitContactResolvers(invoice: nil, onchainAddresses: { address, outputs in
            let revision = await reservations.attributionRevision
            guard let contacts = try? await reservations.contactsForReceipt(
                PaykitReceivedPaymentContacts(), outputAddresses: outputs, expectedRevision: revision
            )
            else { return nil }
            return contacts.contact(receivingAddress: address, outputAddresses: outputs)
        }, receiptOperation: { try await admission.withReceiptAttribution($0) })
        let txid = String(repeating: wipe ? "f" : (ambiguous ? "e" : "d"), count: 64)
        let address = try XCTUnwrap(addresses[7])
        UserDefaults.standard.set(address, forKey: "onchainAddress")
        let outputs = try [UInt32(7), 3].enumerated().map { position, index in
            try BitkitCore.TxOutput(
                scriptpubkey: "",
                scriptpubkeyType: "v0_p2wpkh",
                scriptpubkeyAddress: XCTUnwrap(addresses[index]),
                value: 5000,
                n: UInt32(position)
            )
        }
        let details = BitkitCore.TransactionDetails(walletId: WalletScope.default, txId: txid, amountSats: 10000, inputs: [], outputs: outputs)
        try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [details]) }
        let payment = LDKNode.PaymentDetails(id: txid, kind: .onchain(txid: txid, status: .unconfirmed), amountMsat: 10_000_000,
                                             feePaidMsat: 0, direction: .inbound, status: .succeeded,
                                             latestUpdateTimestamp: UInt64(Date().timeIntervalSince1970))
        let syncing = Task { try await activity.syncLdkNodePayments([payment]) }
        await fulfillment(of: [captured], timeout: 5)
        let cleanup = try admission.reserve(kind: wipe ? .walletWipe : .removal, id: UUID(), expected: admission.snapshot())
        defer {
            _ = try? admission.complete(cleanup)
            admission.release(cleanup)
        }
        if wipe {
            XCTAssertThrowsError(try admission.persist(cleanup), "Wipe cannot pass the captured receipt's database write")
        } else {
            try await admission.drain(before: cleanup)
            try admission.persist(cleanup)
            _ = try await reservations.clearContactAssignmentsForRemoval()
            try admission.complete(cleanup)
        }
        await gate.release()
        try await syncing.value
        let rows = try await activity.get(filter: .onchain, walletId: WalletScope.default)
        guard case let .onchain(row) = try XCTUnwrap(rows.first(where: { $0.activityId == txid })) else { return XCTFail("Missing receipt") }
        XCTAssertEqual(row.value, 10000)
        XCTAssertEqual(row.contact, ambiguous || wipe ? nil : contact)
        if wipe {
            try await admission.drain(before: cleanup)
            try admission.persist(cleanup)
            await reservations.clear()
            try await activity.removeAll()
            try admission.complete(cleanup)
            admission.release(cleanup)
            try await admission.withReceiptAttribution { canAttribute in XCTAssertTrue(canAttribute()) }
            let replacement = try nativeAddresses(directory: directory.appendingPathComponent("replacement"))
            XCTAssertEqual(replacement, addresses, "Same-seed replacement must not restore the ended wallet's association")
            try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [details]) }
            try await activity.syncLdkNodePayments([payment])
            let replaced = try await activity.get(filter: .onchain, walletId: WalletScope.default)
            guard case let .onchain(replacementRow) = try XCTUnwrap(replaced.first) else { return XCTFail("Missing replacement receipt") }
            XCTAssertNil(replacementRow.contact)
        }
    }

    private func nativeAddresses(directory: URL) throws -> [UInt32: String] {
        let builder = Builder()
        builder.setNetwork(network: Env.network)
        builder.setChainSourceEsplora(serverUrl: "http://127.0.0.1:1", config: nil)
        builder.setStorageDirPath(storageDirPath: directory.path)
        try builder.setEntropySeedBytes(seedBytes: [UInt8](repeating: 42, count: 64))
        let node = try builder.build()
        let generated = try (0 ... 7).map { _ in try node.onchainPayment().newAddressInfo() }
        return Dictionary(uniqueKeysWithValues: generated.map { ($0.index, $0.address) })
    }

    private func invoiceService(hash: String, contact: String, admission: ProfileOperationAdmission) throws -> PrivatePaykitService {
        var state = PrivatePaykitService.ContactState()
        state.localInvoice = .init(bolt11: "fixture", paymentHash: hash, expiresAt: Date().timeIntervalSince1970 + 3600)
        try UserDefaults.standard.set(JSONEncoder().encode(PrivatePaykitService.PrivatePaykitState(contacts: [contact: state])),
                                      forKey: PrivatePaykitService.cacheStateKey)
        return PrivatePaykitService(profileAdmission: admission)
    }

    private func invoicePayment(hash: String) -> LDKNode.PaymentDetails {
        LDKNode.PaymentDetails(id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: nil),
                               amountMsat: 5_000_000, feePaidMsat: 0, direction: .inbound, status: .succeeded,
                               latestUpdateTimestamp: UInt64(Date().timeIntervalSince1970))
    }
}

private actor ReceiptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var started = false

    func shouldWait() -> Bool {
        defer { started = true }
        return !started
    }

    func wait() async {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ReceiptWorker {
    private var task: Task<Void, Error>?
    func set(_ task: Task<Void, Error>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
    }
}
