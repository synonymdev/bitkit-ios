@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

@MainActor
final class AppViewModelTests: XCTestCase {
    private let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"

    override func setUp() {
        super.setUp()
        ToastWindowManager.shared.hideToast()
        addTeardownBlock { ToastWindowManager.shared.hideToast() }
    }

    func testBip21AmountUpToBitcoinSupplyOpensOnchainPayment() async throws {
        let app = makeApp()

        try await app.handleScannedData("bitcoin:\(address)?amount=21000000")

        XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, Env.maxBitcoinSats)
    }

    func testBip21AmountAboveBitcoinSupplyIsRejected() async throws {
        // bitkit-core saturates these: 1e11 BTC is 1e19 sats and `inf` is UInt64.max.
        for amount in ["21000000.00000001", "100000000000", "inf"] {
            let app = makeApp()
            ToastWindowManager.shared.hideToast()

            try await app.handleScannedData("bitcoin:\(address)?amount=\(amount)")

            XCTAssertNil(app.scannedOnchainInvoice, amount)
            XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "InvalidAddressToast", amount)
        }
    }

    func testContactEndpointWithAmountAboveBitcoinSupplyIsNotOffered() async throws {
        let usdt = try PaykitUsdt.endpoint(address: "0x4cdDcC65AF3Aa77803d1A99A030eb17751AC7780")
        let request = "bitcoin:\(address)?amount=inf"
        let bitcoin = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh, value: request, min: nil, max: nil, rawPayload: request
        )
        let app = makeApp()
        let context = ContactPaymentContext(publicKey: "contact", endpoints: [usdt, bitcoin])
        XCTAssertTrue(app.claimContactPaymentContext(context))

        try await app.handleScannedData(usdt.paymentRequest, claimedContactPaymentContext: context)

        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testManualEntryRejectsAmountsAboveBitcoinSupply() async {
        let app = AppViewModel()
        let cases: [(String, ManualEntryValidationResult)] = [
            ("bitcoin:\(address)?amount=0.001", .valid),
            ("bitcoin:\(address)?amount=100000000000", .invalid),
            ("bitcoin:\(address)?amount=inf", .invalid),
        ]
        for (input, result) in cases {
            ToastWindowManager.shared.hideToast()
            let validated = expectation(description: "Manual entry validated")
            let observation = app.$manualEntryValidationResult.dropFirst().sink { _ in validated.fulfill() }

            app.validateManualEntryInput(input, savingsBalanceSats: 100_000, spendingBalanceSats: 0)

            await fulfillment(of: [validated], timeout: 5)
            observation.cancel()
            XCTAssertEqual(app.manualEntryValidationResult, result, input)
            if result == .invalid {
                XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "InvalidAddressToast", input)
            }
        }
    }

    func testAUnifiedCodeIsPaidOnchainOnlyOnceItsLightningPaymentFailed() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        let uri = "bitcoin:\(address)?amount=0.0001&lightning=\(Self.expiredRegtestBolt11)"
        let payments = PaymentStore(payments: [Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)])
        let app = makeApp(listPayments: { await payments.list() })

        for (status, toast) in [(PaymentStatus.pending, "LightningPaymentPendingToast"), (.succeeded, "LightningPaymentSucceededToast")] {
            await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: status)])
            ToastWindowManager.shared.hideToast()

            try await app.handleScannedData(uri)

            XCTAssertNil(app.scannedOnchainInvoice, "\(status)")
            XCTAssertTrue(app.didRejectScannedPayment, "\(status)")
            XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, toast)
        }

        await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .failed)])
        ToastWindowManager.shared.hideToast()

        try await app.handleScannedData(uri)

        XCTAssertEqual(app.scannedOnchainInvoice?.address, address)
        XCTAssertFalse(app.didRejectScannedPayment)
        XCTAssertNil(ToastWindowManager.shared.currentToast)
        XCTAssertEqual(app.scannedLightningPaymentHash, paymentHash, "The address is checked again before it is paid")
    }

    func testAUnifiedCodeScannedBeforeTheNodeRunsIsPaidOnchainOnlyOnceTheNodeShowsItUnpaid() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        let payments = PaymentStore(payments: nil)
        let app = makeApp(listPayments: { await payments.list() })

        try await app.handleScannedData("bitcoin:\(address)?amount=0.0001&lightning=\(Self.expiredRegtestBolt11)")

        XCTAssertEqual(app.scannedOnchainInvoice?.address, address)
        XCTAssertNil(app.scannedLightningInvoice)
        XCTAssertFalse(app.didRejectScannedPayment)
        XCTAssertEqual(app.scannedLightningPaymentHash, paymentHash)
        await app.refreshScannedAddressBlocked()
        XCTAssertTrue(app.isScannedAddressBlocked)
        let refusalBeforeTheNodeRuns = await confirmRefusal(app)
        XCTAssertEqual(refusalBeforeTheNodeRuns, .unknown)

        let cases: [(payment: LDKNode.PaymentDetails, refusal: LightningPaymentStatus?)] = [
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending), .pending),
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .succeeded), .succeeded),
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .failed), nil),
        ]
        for (payment, refusal) in cases {
            await payments.set([payment])

            await app.refreshScannedAddressBlocked()
            let refusalOnceTheNodeRuns = await confirmRefusal(app)

            XCTAssertEqual(app.isScannedAddressBlocked, refusal != nil, "\(payment.status)")
            XCTAssertEqual(refusalOnceTheNodeRuns, refusal, "\(payment.status)")
        }
    }

    func testAHardwareSendOfAUnifiedCodeKeepsItsInvoiceForConfirmToCheckWithoutOfferingLightning() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        let payments = PaymentStore(payments: nil)
        let app = makeApp(listPayments: { await payments.list() })

        try await app.handleScannedData(
            "bitcoin:\(address)?amount=0.0001&lightning=\(Self.expiredRegtestBolt11)",
            scope: .onchainPayments
        )

        await assertConfirmPaysTheAddressOnlyOnceItsLightningPaymentFailed(app, paymentHash: paymentHash, payments: payments)
    }

    func testAHardwareSendToAContactKeepsTheContactsInvoiceForConfirmToCheck() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        // A contact whose invoice was published with a scheme, as some apps do
        for bolt11 in [Self.expiredRegtestBolt11, "lightning:\(Self.expiredRegtestBolt11)", "LIGHTNING:\(Self.expiredRegtestBolt11)"] {
            let payments = PaymentStore(payments: nil)
            let app = makeApp(listPayments: { await payments.list() })
            let context = ContactPaymentContext(publicKey: "contact", endpoints: Self.contactEndpoints(address: address, bolt11: bolt11))
            XCTAssertTrue(app.claimContactPaymentContext(context))

            try await app.handleScannedData(
                PublicPaykitService.paymentRequest(from: context.endpoints), claimedContactPaymentContext: context, scope: .onchainPayments
            )

            await assertConfirmPaysTheAddressOnlyOnceItsLightningPaymentFailed(app, paymentHash: paymentHash, payments: payments)
        }
    }

    func testAHardwareScanRefusesAnAddressWhoseInvoiceMayStillBePaidOrWas() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        let refusals: [(status: PaymentStatus, toast: String)] = [
            (.pending, "LightningPaymentPendingToast"), (.succeeded, "LightningPaymentSucceededToast"),
        ]
        for (status, toast) in refusals {
            let payments = PaymentStore(payments: [Self.outboundBolt11Payment(paymentHash: paymentHash, status: status)])
            let unifiedCode = makeApp(listPayments: { await payments.list() })
            ToastWindowManager.shared.hideToast()

            try await unifiedCode.handleScannedData(
                "bitcoin:\(address)?amount=0.0001&lightning=\(Self.expiredRegtestBolt11)",
                scope: .onchainPayments
            )

            XCTAssertNil(unifiedCode.scannedOnchainInvoice, "\(status)")
            XCTAssertTrue(unifiedCode.didRejectScannedPayment, "\(status)")
            XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, toast)

            let contact = makeApp(listPayments: { await payments.list() })
            let context = ContactPaymentContext(publicKey: "contact", endpoints: Self.contactEndpoints(address: address))
            XCTAssertTrue(contact.claimContactPaymentContext(context))
            ToastWindowManager.shared.hideToast()

            try await contact.handleScannedData(
                PublicPaykitService.paymentRequest(from: context.endpoints), claimedContactPaymentContext: context, scope: .onchainPayments
            )

            XCTAssertNil(contact.scannedOnchainInvoice, "\(status)")
            XCTAssertTrue(contact.didRejectScannedPayment, "\(status)")
            XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, toast)
        }
    }

    func testAHardwareSendHeldForItsLightningCheckKeepsItsWalletOnTheAmountScreen() async throws {
        let payments = PaymentStore(payments: nil)
        let app = makeApp(listPayments: { await payments.list() })
        try await app.handleScannedData(
            "bitcoin:\(address)?amount=0.0001&lightning=\(Self.expiredRegtestBolt11)",
            scope: .onchainPayments
        )
        await app.refreshScannedAddressBlocked()
        XCTAssertTrue(app.isScannedAddressBlocked)
        let hardware = SendFundingSource.hardware(walletId: "hardware")

        XCTAssertNil(SendAmountView.fundingSourceReplacing(hardware, offered: [.usdt], isHeldHardwareSend: app.isScannedAddressBlocked))
        XCTAssertEqual(SendAmountView.fundingSourceReplacing(hardware, offered: [.usdt], isHeldHardwareSend: false), .usdt)
        XCTAssertNil(SendAmountView.fundingSourceReplacing(hardware, offered: [hardware, .usdt], isHeldHardwareSend: false))
    }

    func testAnUppercaseUnifiedCodeKeepsItsInvoiceInBothScopes() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        let uri = "BITCOIN:\(address.uppercased())?AMOUNT=0.0001&LIGHTNING=\(Self.expiredRegtestBolt11.uppercased())"
        for scope in [ScanHandlingScope.unrestricted, .onchainPayments] {
            let payments = PaymentStore(payments: [])
            let app = makeApp(listPayments: { await payments.list() })

            try await app.handleScannedData(uri, scope: scope)

            XCTAssertEqual(app.scannedOnchainInvoice?.address.lowercased(), address, "\(scope)")
            XCTAssertNil(app.scannedLightningInvoice, "\(scope)")
            XCTAssertEqual(app.scannedLightningPaymentHash, paymentHash, "\(scope)")

            await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)])
            ToastWindowManager.shared.hideToast()

            try await app.handleScannedData(uri, scope: scope)

            XCTAssertNil(app.scannedOnchainInvoice, "\(scope)")
            XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "LightningPaymentPendingToast", "\(scope)")
        }
    }

    func testAnInvoiceThisNodeIssuedIsNeverCheckedBeforeItsAddressIsPaid() async throws {
        let payee = try Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).recoverPayeePubKey()
        let uri = "bitcoin:\(address)?amount=0.0001&lightning=\(Self.expiredRegtestBolt11)"
        for nodeId in [payee, payee.uppercased()] {
            for scope in [ScanHandlingScope.unrestricted, .onchainPayments] {
                let storeReads = Counter()
                let app = makeApp(
                    listPayments: {
                        storeReads.value += 1
                        return nil
                    },
                    nodeId: { nodeId }
                )

                try await app.handleScannedData(uri, scope: scope)
                let refusal = await confirmRefusal(app)

                XCTAssertEqual(app.scannedOnchainInvoice?.address, address, "\(scope)")
                XCTAssertNil(app.scannedLightningPaymentHash, "\(scope)")
                XCTAssertNil(refusal, "\(scope)")
                XCTAssertEqual(storeReads.value, 0, "\(scope)")
            }
        }

        let contact = makeApp(listPayments: { nil }, nodeId: { payee })
        let context = ContactPaymentContext(publicKey: "contact", endpoints: Self.contactEndpoints(address: address))
        XCTAssertTrue(contact.claimContactPaymentContext(context))
        try await contact.handleScannedData(
            PublicPaykitService.paymentRequest(from: context.endpoints), claimedContactPaymentContext: context, scope: .onchainPayments
        )
        XCTAssertEqual(contact.scannedOnchainInvoice?.address, address)
        XCTAssertNil(contact.scannedLightningPaymentHash)

        let otherNode = makeApp(listPayments: { nil }, nodeId: { String(repeating: "02", count: 33) })
        try await otherNode.handleScannedData(uri, scope: .onchainPayments)
        XCTAssertNotNil(otherNode.scannedLightningPaymentHash, "Another node's invoice is checked")
    }

    func testEveryOnchainRefusalSaysWhyUnderTheSameTitle() {
        let cases: [(status: LightningPaymentStatus, description: String, toast: String)] = [
            (.pending, "wallet__send_onchain_lightning_pending", "LightningPaymentPendingToast"),
            (.succeeded, "wallet__send_onchain_lightning_paid", "LightningPaymentSucceededToast"),
            (.unknown, "wallet__send_onchain_lightning_unknown", "LightningPaymentUnknownToast"),
        ]
        let app = makeApp()
        for (status, description, toast) in cases {
            ToastWindowManager.shared.hideToast()

            app.showOnchainPaymentRefusal(OnchainPaymentRefusal(status))

            let shown = ToastWindowManager.shared.currentToast
            XCTAssertEqual(shown?.title, t("common__error"), "\(status)")
            XCTAssertNotEqual(shown?.title, t("wallet__send_pending"), "\(status)")
            XCTAssertNotEqual(shown?.title, t("wallet__toast_payment_success_title"), "\(status)")
            XCTAssertEqual(shown?.description, t(description), "\(status)")
            XCTAssertEqual(shown?.accessibilityIdentifier, toast, "\(status)")
            XCTAssertEqual(OnchainPaymentRefusal(status).errorDescription, t(description), "\(status)")
        }
    }

    func testTheSyncFallbackKeepsTheInvoicesHashAndChecksTheSendAgainAfterReadingTheStore() async throws {
        let paymentHash = String(repeating: "ab", count: 32)
        let payments = PaymentStore(payments: [])
        let app = makeApp(listPayments: { await payments.list() })
        setUnifiedSend(app, paymentHash: paymentHash)
        app.selectedWalletToPayFrom = .lightning
        let lightningInvoice = try XCTUnwrap(app.scannedLightningInvoice)
        let onchainInvoice = try XCTUnwrap(app.scannedOnchainInvoice)

        // The send went out, as Confirm sent it, while the store was read
        let didReadStore = Counter()
        let wentOutWhileReading = makeApp(listPayments: {
            didReadStore.value += 1
            return []
        })
        setUnifiedSend(wentOutWhileReading, paymentHash: paymentHash)
        wentOutWhileReading.selectedWalletToPayFrom = .lightning
        let superseded = await wentOutWhileReading.fallBackToOnchain(from: lightningInvoice, to: onchainInvoice) { didReadStore.value == 0 }
        XCTAssertEqual(superseded, .superseded)
        XCTAssertEqual(wentOutWhileReading.scannedLightningInvoice, lightningInvoice)
        XCTAssertEqual(wentOutWhileReading.selectedWalletToPayFrom, .lightning)

        for status in [PaymentStatus.pending, .succeeded] {
            await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: status)])
            let refused = await app.fallBackToOnchain(from: lightningInvoice, to: onchainInvoice) { true }
            XCTAssertEqual(refused, .refused(status == .pending ? .pending : .succeeded))
            XCTAssertEqual(app.scannedLightningInvoice, lightningInvoice, "\(status)")
            XCTAssertEqual(app.selectedWalletToPayFrom, .lightning, "\(status)")
        }

        await payments.set([])
        let outcome = await app.fallBackToOnchain(from: lightningInvoice, to: onchainInvoice) { true }

        XCTAssertEqual(outcome, .fellBack)
        XCTAssertNil(app.scannedLightningInvoice)
        XCTAssertEqual(app.scannedOnchainInvoice, onchainInvoice)
        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
        XCTAssertEqual(app.scannedLightningPaymentHash, paymentHash)
        await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)])
        let refusal = await confirmRefusal(app)
        XCTAssertEqual(refusal, .pending, "Confirm checks the kept hash again")
    }

    func testAContactWhoseInvoiceIsBeingPaidIsNotPaidOnchainAsWell() async throws {
        let paymentHash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.expiredRegtestBolt11).paymentHash())
        let payments = PaymentStore(payments: [Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)])
        let app = makeApp(listPayments: { await payments.list() })
        let endpoints = Self.contactEndpoints(address: address)

        let context = ContactPaymentContext(publicKey: "contact", endpoints: endpoints)
        XCTAssertTrue(app.claimContactPaymentContext(context))
        try await app.handleScannedData(PublicPaykitService.paymentRequest(from: endpoints), claimedContactPaymentContext: context)

        XCTAssertNil(app.scannedOnchainInvoice)
        XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "LightningPaymentPendingToast")

        await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .failed)])
        ToastWindowManager.shared.hideToast()
        app.resetSendState()
        let retry = ContactPaymentContext(publicKey: "contact", endpoints: endpoints)
        XCTAssertTrue(app.claimContactPaymentContext(retry))
        try await app.handleScannedData(PublicPaykitService.paymentRequest(from: endpoints), claimedContactPaymentContext: retry)

        XCTAssertEqual(app.scannedOnchainInvoice?.address, address)
        XCTAssertEqual(app.scannedLightningPaymentHash, paymentHash)
    }

    func testALightningPaymentStatusIsTheNodesOutboundPaymentOfTheInvoice() async {
        let paymentHash = String(repeating: "ab", count: 32)
        let cases: [(payment: LDKNode.PaymentDetails, status: LightningPaymentStatus)] = [
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending), .pending),
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .succeeded), .succeeded),
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .failed), .unpaid),
            (Self.outboundBolt11Payment(paymentHash: String(repeating: "cd", count: 32), status: .pending), .unpaid),
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending, direction: .inbound), .unpaid),
            (Self.outboundBolt11Payment(paymentHash: paymentHash, status: .succeeded, direction: .inbound), .unpaid),
        ]
        for (index, entry) in cases.enumerated() {
            let app = makeApp(listPayments: { [entry.payment] })

            let status = await app.lightningPaymentStatus(paymentHash: paymentHash)

            XCTAssertEqual(status, entry.status, "case \(index)")
        }
    }

    func testAPaymentStoreThatCannotBeReadNeverShowsTheInvoiceUnpaid() async {
        let paymentHash = String(repeating: "ab", count: 32)
        let app = makeApp(listPayments: { nil })

        let status = await app.lightningPaymentStatus(paymentHash: paymentHash)
        app.addPendingPaymentHash(paymentHash)
        let statusWhileTheSheetAwaitsIt = await app.lightningPaymentStatus(paymentHash: paymentHash)

        XCTAssertEqual(status, .unknown)
        XCTAssertEqual(statusWhileTheSheetAwaitsIt, .pending)
    }

    func testThePickersOfferTheScannedAddressOnlyWhileItsInvoiceIsUnpaid() async {
        let paymentHash = String(repeating: "ab", count: 32)
        let cases: [(payments: [LDKNode.PaymentDetails]?, isBlocked: Bool)] = [
            ([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)], true),
            ([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .succeeded)], true),
            (nil, true),
            ([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .failed)], false),
            ([], false),
        ]
        for (index, entry) in cases.enumerated() {
            let app = makeApp(listPayments: { entry.payments })
            setUnifiedSend(app, paymentHash: paymentHash)

            await app.refreshScannedAddressBlocked()

            XCTAssertEqual(app.isScannedAddressBlocked, entry.isBlocked, "case \(index)")
        }

        let storeReads = Counter()
        let app = makeApp(listPayments: {
            storeReads.value += 1
            return nil
        })
        app.scannedOnchainInvoice = OnChainInvoice(address: address, amountSatoshis: 0, label: nil, message: nil, params: nil)
        await app.refreshScannedAddressBlocked()
        XCTAssertFalse(app.isScannedAddressBlocked, "An address that came with no invoice")
        XCTAssertEqual(storeReads.value, 0)
    }

    func testTheScannedAddressIsOfferedAgainOnceItsLightningPaymentFailsButNotOnceItSucceeds() async throws {
        let paymentHash = String(repeating: "ab", count: 32)
        let events: [(event: LDKNode.Event, isBlocked: Bool)] = [
            (.paymentFailed(paymentId: paymentHash, paymentHash: paymentHash, reason: .retriesExhausted), false),
            (.paymentSuccessful(paymentId: paymentHash, paymentHash: paymentHash, paymentPreimage: nil, feePaidMsat: nil), true),
        ]
        for (event, isBlocked) in events {
            // A store that would show the invoice unpaid if it were read again
            let app = makeApp(listPayments: { [] })
            setUnifiedSend(app, paymentHash: paymentHash)
            app.addPendingPaymentHash(paymentHash)
            await app.refreshScannedAddressBlocked()
            XCTAssertTrue(app.isScannedAddressBlocked, "\(event)")

            app.handleLdkNodeEvent(event)

            for _ in 0 ..< 100 where app.isScannedAddressBlocked != isBlocked {
                try await Task.sleep(for: .milliseconds(20))
            }
            await Self.settle()
            XCTAssertEqual(app.isScannedAddressBlocked, isBlocked, "\(event)")
            ToastWindowManager.shared.hideToast()
        }
    }

    func testAPaymentAwaitingTheSendSheetIsPendingUntilItFails() async {
        let paymentHash = String(repeating: "ef", count: 32)
        let app = makeApp()
        app.addPendingPaymentHash(paymentHash)

        let statusBeforeFailure = await app.lightningPaymentStatus(paymentHash: paymentHash)
        XCTAssertEqual(statusBeforeFailure, .pending)

        app.handleLdkNodeEvent(.paymentFailed(paymentId: paymentHash, paymentHash: paymentHash, reason: .retriesExhausted))

        let statusAfterFailure = await app.lightningPaymentStatus(paymentHash: paymentHash)
        XCTAssertEqual(statusAfterFailure, .unpaid)
    }

    /// Checks a send that pays only an address which came with an invoice, scanned before the node's payment store could be read:
    /// Confirm refuses it, before the hardware wallet signs as before a software send, while that cannot be read and while a
    /// Lightning payment of the invoice is pending, and lets it go once the payment failed.
    private func assertConfirmPaysTheAddressOnlyOnceItsLightningPaymentFailed(
        _ app: AppViewModel,
        paymentHash: String,
        payments: PaymentStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertEqual(app.scannedOnchainInvoice?.address, address, file: file, line: line)
        XCTAssertNil(app.scannedLightningInvoice, "Lightning is never offered", file: file, line: line)
        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain, file: file, line: line)
        XCTAssertEqual(app.scannedLightningPaymentHash, paymentHash, file: file, line: line)
        await app.refreshScannedAddressBlocked()
        XCTAssertTrue(app.isScannedAddressBlocked, file: file, line: line)
        let refusalBeforeTheNodeRuns = await confirmRefusal(app)
        XCTAssertEqual(refusalBeforeTheNodeRuns, .unknown, file: file, line: line)

        await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)])
        let refusalWhilePending = await confirmRefusal(app)
        XCTAssertEqual(refusalWhilePending, .pending, file: file, line: line)

        await payments.set([Self.outboundBolt11Payment(paymentHash: paymentHash, status: .failed)])

        let refusalOnceFailed = await confirmRefusal(app)
        XCTAssertNil(refusalOnceFailed, file: file, line: line)
    }

    /// What Confirm decides for the send as it stands, before it sends it or the hardware wallet signs it.
    private func confirmRefusal(_ app: AppViewModel) async -> LightningPaymentStatus? {
        await SendConfirmationView.onchainDispatchRefusal(
            walletType: app.selectedWalletToPayFrom,
            lightningPaymentHash: app.scannedLightningPaymentHash,
            lightningPaymentStatus: app.lightningPaymentStatus
        )?.status
    }

    private func setUnifiedSend(_ app: AppViewModel, paymentHash: String) {
        app.scannedOnchainInvoice = OnChainInvoice(address: address, amountSatoshis: 0, label: nil, message: nil, params: nil)
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: "test-invoice", paymentHash: paymentHash.hexaData, amountSatoshis: 0, timestampSeconds: 0, expirySeconds: 0,
            isExpired: false, description: nil, networkType: .regtest, payeeNodeId: nil
        )
    }

    /// Lets a refresh started by a node event run, so a test can check that none changed what the pickers offer.
    private static func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    private static func contactEndpoints(address: String, bolt11: String = expiredRegtestBolt11) -> [PublicPaykitService.Endpoint] {
        [
            PublicPaykitService.Endpoint(methodId: .bitcoinLightningBolt11, value: bolt11, min: nil, max: nil, rawPayload: bolt11),
            PublicPaykitService.Endpoint(methodId: .regtestOnchainP2wpkh, value: address, min: nil, max: nil, rawPayload: address),
        ]
    }

    private nonisolated static let expiredRegtestBolt11 =
        "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"

    nonisolated static func outboundBolt11Payment(
        paymentHash: String,
        status: PaymentStatus,
        direction: PaymentDirection = .outbound
    ) -> LDKNode.PaymentDetails {
        LDKNode.PaymentDetails(
            id: paymentHash,
            kind: .bolt11(hash: paymentHash, preimage: nil, secret: nil, description: nil, bolt11: nil),
            amountMsat: 20000, feePaidMsat: nil, direction: direction, status: status,
            latestUpdateTimestamp: 0
        )
    }

    private func makeApp(
        listPayments: @escaping () async -> [LDKNode.PaymentDetails]? = { [] },
        nodeId: @escaping () -> String? = { nil }
    ) -> AppViewModel {
        AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: false,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 0,
                        hasChannels: false,
                        hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false },
                listPayments: listPayments,
                nodeId: nodeId
            )
        )
    }
}

/// The node's payments, which a test changes between scans, or nil while the node's payment store cannot be read.
private actor PaymentStore {
    private var payments: [LDKNode.PaymentDetails]?

    init(payments: [LDKNode.PaymentDetails]?) {
        self.payments = payments
    }

    func list() -> [LDKNode.PaymentDetails]? {
        payments
    }

    func set(_ payments: [LDKNode.PaymentDetails]?) {
        self.payments = payments
    }
}

private final class Counter {
    var value = 0
}
