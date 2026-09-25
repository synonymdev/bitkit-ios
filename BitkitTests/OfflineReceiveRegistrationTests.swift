@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class OfflineReceiveRegistrationTests: XCTestCase {
    func testAlreadySettledInvoiceCannotRegister() async {
        let invoice = validatedInvoice()
        let registration = OfflineReceiveRegistration(payments: { [self.payment(hash: invoice.paymentHash)] })
        await assertUnavailable { try await registration.register(invoice, revision: registration.revision) }
        XCTAssertFalse(registration.contains(invoice))
    }

    func testUnavailableHistoryCannotRegister() async {
        let invoice = validatedInvoice()
        let registration = OfflineReceiveRegistration(payments: { nil })
        await assertUnavailable { try await registration.register(invoice, revision: registration.revision) }
        XCTAssertFalse(registration.contains(invoice))
    }

    func testOnlyMatchingSucceededInboundBolt11EstablishesPayment() async throws {
        let invoice = validatedInvoice()
        let registration = OfflineReceiveRegistration(payments: {
            [
                self.payment(hash: "another-hash"),
                self.payment(hash: invoice.paymentHash, status: .pending),
                self.payment(hash: invoice.paymentHash, status: .failed),
                self.payment(hash: invoice.paymentHash, direction: .outbound),
            ]
        })
        try await registration.register(invoice, revision: registration.revision)
        XCTAssertTrue(registration.contains(invoice))
    }

    func testPaymentDuringHistoryReadRetriesSnapshotAndRejectsPaidInvoice() async {
        let invoice = validatedInvoice()
        var reads = 0
        var registration: OfflineReceiveRegistration!
        registration = OfflineReceiveRegistration(payments: {
            reads += 1
            if reads == 1 {
                registration.paymentReceived(hash: invoice.paymentHash)
                return [] // The lookup began before the payment was recorded.
            }
            return [self.payment(hash: invoice.paymentHash)]
        })
        await assertUnavailable { try await registration.register(invoice, revision: registration.revision) }
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(registration.contains(invoice))
    }

    func testUnrelatedEventDuringHistoryReadRetriesWithoutMarkingInvoicePaid() async throws {
        let invoice = validatedInvoice()
        var reads = 0
        var registration: OfflineReceiveRegistration!
        registration = OfflineReceiveRegistration(payments: {
            reads += 1
            if reads == 1 { registration.paymentReceived(hash: "another-hash") }
            return [self.payment(hash: "another-hash")]
        })
        try await registration.register(invoice, revision: registration.revision)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(registration.contains(invoice))
    }

    func testSessionResetDuringHistoryReadRejectsCandidate() async {
        let invoice = validatedInvoice()
        var registration: OfflineReceiveRegistration!
        registration = OfflineReceiveRegistration(payments: {
            registration.reset()
            return []
        })
        await assertUnavailable { try await registration.register(invoice, revision: registration.revision) }
        XCTAssertFalse(registration.contains(invoice))
    }

    func testStaleSessionDoesNotEvenQueryHistory() async {
        let invoice = validatedInvoice()
        var reads = 0
        let registration = OfflineReceiveRegistration(payments: { reads += 1; return [] })
        let revision = registration.revision
        registration.reset()
        await assertUnavailable { try await registration.register(invoice, revision: revision) }
        XCTAssertEqual(reads, 0)
    }

    func testOlderPreparationCannotReplaceNewerDisplayedInvoice() async throws {
        let oldInvoice = validatedInvoice()
        let newerInvoice = OfflineReceiveInvoice(
            bolt11: "newer-validated-invoice", amountSats: 2000, note: "Edited note",
            paymentHash: "newer-payment-hash", expiresAt: Date().addingTimeInterval(600)
        )
        let olderReadStarted = expectation(description: "older history lookup suspended")
        var olderRead: CheckedContinuation<[PaymentDetails]?, Never>?
        var reads = 0
        let wallet = WalletViewModel(offlineReceivePayments: {
            reads += 1
            if reads == 1 {
                return await withCheckedContinuation { continuation in
                    olderRead = continuation
                    olderReadStarted.fulfill()
                }
            }
            return []
        })
        wallet.invoiceReceiveOffline = true
        let registration = wallet.offlineInvoiceRegistration
        let oldRevision = registration.beginPreparation()
        let oldAttempt = Task { @MainActor in
            await self.assertUnavailable { try await registration.register(oldInvoice, revision: oldRevision) }
        }
        await fulfillment(of: [olderReadStarted], timeout: 2)

        wallet.invoiceAmountSats = newerInvoice.amountSats
        wallet.invoiceNote = newerInvoice.note
        let newRevision = registration.beginPreparation()
        try await registration.register(newerInvoice, revision: newRevision)
        try wallet.applyReceiveInvoice(bolt11: newerInvoice.bolt11, offlineInvoice: newerInvoice, bip21: "newer-offline-uri")
        XCTAssertTrue(wallet.hasPreparedOfflineInvoice)

        olderRead?.resume(returning: [])
        await oldAttempt.value
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(registration.contains(newerInvoice))
        XCTAssertFalse(registration.contains(oldInvoice))
        XCTAssertTrue(wallet.hasPreparedOfflineInvoice)
        XCTAssertEqual(wallet.bolt11, newerInvoice.bolt11)
    }

    func testPaymentBetweenHistoryAndDisplayCannotInstallInvoice() async throws {
        let invoice = validatedInvoice()
        let wallet = walletForOfflineInvoice(invoice)
        try await wallet.offlineInvoiceRegistration.register(invoice, revision: wallet.offlineInvoiceRegistration.revision)
        wallet.receiveInvoicePaymentReceived(hash: invoice.paymentHash)

        XCTAssertThrowsError(try wallet.applyReceiveInvoice(bolt11: invoice.bolt11, offlineInvoice: invoice, bip21: "offline-uri"))
        XCTAssertNil(wallet.offlineInvoice)
        XCTAssertEqual(wallet.bolt11, "")
        XCTAssertEqual(wallet.bip21, "")
        XCTAssertFalse(wallet.hasPreparedOfflineInvoice)
    }

    func testResetBetweenHistoryAndDisplayCannotInstallInvoice() async throws {
        let invoice = validatedInvoice()
        let wallet = walletForOfflineInvoice(invoice)
        try await wallet.offlineInvoiceRegistration.register(invoice, revision: wallet.offlineInvoiceRegistration.revision)
        wallet.resetOfflineReceive()
        wallet.invoiceReceiveOffline = true

        XCTAssertThrowsError(try wallet.applyReceiveInvoice(bolt11: invoice.bolt11, offlineInvoice: invoice, bip21: "offline-uri"))
        XCTAssertNil(wallet.offlineInvoice)
        XCTAssertFalse(wallet.hasPreparedOfflineInvoice)
    }

    func testOnlyMatchingPaymentClearsDisplayedOfflineInvoice() async throws {
        let invoice = validatedInvoice()
        let wallet = walletForOfflineInvoice(invoice)
        try await wallet.offlineInvoiceRegistration.register(invoice, revision: wallet.offlineInvoiceRegistration.revision)
        try wallet.applyReceiveInvoice(bolt11: invoice.bolt11, offlineInvoice: invoice, bip21: "offline-uri")
        wallet.receiveInvoicePaymentReceived(hash: "another-hash")
        XCTAssertTrue(wallet.hasPreparedOfflineInvoice)
        XCTAssertEqual(wallet.bolt11, invoice.bolt11)

        wallet.receiveInvoicePaymentReceived(hash: invoice.paymentHash)
        XCTAssertFalse(wallet.hasPreparedOfflineInvoice)
        XCTAssertNil(wallet.offlineInvoice)
        XCTAssertEqual(wallet.bolt11, "")
        XCTAssertEqual(wallet.bip21, "")
    }

    func testOfflineInvoiceNeverChangesOrdinaryAppStorageOrSurvivesRecreation() async throws {
        let defaults = UserDefaults.standard
        let previousBolt11 = defaults.object(forKey: "bolt11")
        let previousBip21 = defaults.object(forKey: "bip21")
        defer {
            defaults.set(previousBolt11, forKey: "bolt11")
            defaults.set(previousBip21, forKey: "bip21")
        }
        let ordinaryWallet = WalletViewModel()
        ordinaryWallet.bolt11 = "ordinary-invoice"
        ordinaryWallet.bip21 = "ordinary-uri"
        let invoice = validatedInvoice()
        let wallet = walletForOfflineInvoice(invoice)
        try await wallet.offlineInvoiceRegistration.register(invoice, revision: wallet.offlineInvoiceRegistration.revision)
        try wallet.applyReceiveInvoice(bolt11: invoice.bolt11, offlineInvoice: invoice, bip21: "offline-uri")

        XCTAssertEqual(defaults.string(forKey: "bolt11"), "ordinary-invoice")
        XCTAssertEqual(defaults.string(forKey: "bip21"), "ordinary-uri")
        XCTAssertEqual(wallet.bolt11, invoice.bolt11)
        XCTAssertEqual(wallet.bip21, "offline-uri")
        let reopened = WalletViewModel()
        XCTAssertEqual(reopened.bolt11, "ordinary-invoice")
        XCTAssertEqual(reopened.bip21, "ordinary-uri")
        XCTAssertNil(reopened.offlineInvoice)
        XCTAssertFalse(reopened.invoiceReceiveOffline)

        wallet.resetOfflineReceive()
        wallet.invoiceReceiveOffline = true
        XCTAssertEqual(wallet.bolt11, "")
        XCTAssertEqual(wallet.bip21, "")
    }

    func testExpiryClearsOfflineDisplayAndRegistration() async throws {
        let invoice = validatedInvoice()
        let wallet = walletForOfflineInvoice(invoice)
        try await wallet.offlineInvoiceRegistration.register(invoice, revision: wallet.offlineInvoiceRegistration.revision)
        try wallet.applyReceiveInvoice(bolt11: invoice.bolt11, offlineInvoice: invoice, bip21: "offline-uri")
        wallet.expireOfflineInvoice(now: invoice.expiresAt)
        XCTAssertFalse(wallet.hasPreparedOfflineInvoice)
        XCTAssertFalse(wallet.offlineInvoiceRegistration.contains(invoice))
        XCTAssertNil(wallet.offlineInvoice)
        XCTAssertEqual(wallet.bolt11, "")
        XCTAssertEqual(wallet.bip21, "")
    }

    func testOrdinaryPaymentDuringOfflineDisplayCannotResurrectOrdinaryCache() async throws {
        let defaults = UserDefaults.standard
        let previousBolt11 = defaults.object(forKey: "bolt11")
        let previousBip21 = defaults.object(forKey: "bip21")
        defer {
            defaults.set(previousBolt11, forKey: "bolt11")
            defaults.set(previousBip21, forKey: "bip21")
        }
        let invoice = validatedInvoice()
        let wallet = WalletViewModel(offlineReceivePayments: { [] })
        wallet.bolt11 = "ordinary-invoice"
        wallet.bip21 = "ordinary-uri"
        wallet.invoiceReceiveOffline = true
        wallet.invoiceAmountSats = invoice.amountSats
        wallet.invoiceNote = invoice.note
        try await wallet.offlineInvoiceRegistration.register(invoice, revision: wallet.offlineInvoiceRegistration.revision)
        try wallet.applyReceiveInvoice(bolt11: invoice.bolt11, offlineInvoice: invoice, bip21: "offline-uri")

        wallet.receiveInvoicePaymentReceived(hash: "ordinary-payment-hash")
        XCTAssertTrue(wallet.hasPreparedOfflineInvoice)
        XCTAssertEqual(wallet.bolt11, invoice.bolt11)
        XCTAssertEqual(wallet.bip21, "offline-uri")
        XCTAssertEqual(defaults.string(forKey: "bolt11"), "")
        XCTAssertEqual(defaults.string(forKey: "bip21"), "")

        wallet.resetOfflineReceive()
        XCTAssertEqual(wallet.bolt11, "")
        XCTAssertEqual(wallet.bip21, "")
        let reopened = WalletViewModel()
        XCTAssertEqual(reopened.bolt11, "")
        XCTAssertEqual(reopened.bip21, "")
    }

    private func walletForOfflineInvoice(_ invoice: OfflineReceiveInvoice) -> WalletViewModel {
        let wallet = WalletViewModel(offlineReceivePayments: { [] })
        wallet.invoiceReceiveOffline = true
        wallet.invoiceAmountSats = invoice.amountSats
        wallet.invoiceNote = invoice.note
        return wallet
    }

    private func validatedInvoice() -> OfflineReceiveInvoice {
        OfflineReceiveInvoice(
            bolt11: "validated-offline-invoice", amountSats: 1000, note: "Offline",
            paymentHash: "offline-payment-hash", expiresAt: Date().addingTimeInterval(600)
        )
    }

    private func payment(hash: String, status: PaymentStatus = .succeeded, direction: PaymentDirection = .inbound) -> PaymentDetails {
        PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: nil),
            amountMsat: 1_000_000, feePaidMsat: nil, direction: direction, status: status, latestUpdateTimestamp: 0
        )
    }

    private func assertUnavailable(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected offline receive to refuse the invoice")
        } catch OfflineReceiveError.unavailable {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
