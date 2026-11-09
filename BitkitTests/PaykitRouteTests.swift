@testable import Bitkit
import BitkitCore
import BreezSdkSpark
import Paykit
import XCTest

final class PaykitRouteTests: XCTestCase {
    private let onchain = PaykitEndpoint(methodId: "btc-regtest-p2wpkh", value: "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x")
    private let lightning = PaykitEndpoint(
        methodId: "btc-lightning-lnurl",
        value: "lnurl1dp68gurn8ghj7um9wfmxjcm99e3k7mf0v9cxj0m385ekvcenxc6r2c35xvukxefcv5mkvv34x5ekzd3ev56nyd3hxqurzepexejxxepnxscrvwfnv9nxzcn9xq6xyefhvgcxxcmyxymnserxfq5fns"
    )

    private func sparkLeg(amountSats: UInt64, feeSats: UInt64) -> ServiceRouteLeg {
        ServiceRouteLeg(
            service: SparkManager.routeService,
            endpoint: onchain,
            deliveredSat: amountSats,
            debitSat: amountSats + feeSats,
            atomicity: "trusted",
            validUntilUnix: UInt64(Date().timeIntervalSince1970) + 600
        )
    }

    // MARK: - Request

    func testSpendingOffersEveryEndpointAndSavingsOnlyTheOnchainOnes() {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: true)
        let leg = sparkLeg(amountSats: 20000, feeSats: 300)

        let spending = PaykitRouteService.request(
            route: route, amountSats: 20000, source: .spending, lightningSpendableSats: 50000, onchainSpendableSats: 90000,
            serviceLegs: [leg]
        )
        let savings = PaykitRouteService.request(
            route: route, amountSats: 20000, source: .savings, lightningSpendableSats: 50000, onchainSpendableSats: 90000,
            serviceLegs: [leg]
        )

        XCTAssertEqual(spending.contactEndpoints, [lightning, onchain])
        XCTAssertEqual(spending.lightningSpendableSat, 50000)
        XCTAssertEqual(spending.onchainSpendableSat, 0)
        XCTAssertEqual(spending.serviceLegs, [leg])
        XCTAssertEqual(savings.contactEndpoints, [onchain])
        XCTAssertEqual(savings.lightningSpendableSat, 0)
        XCTAssertEqual(savings.onchainSpendableSat, 90000)
        XCTAssertTrue(savings.serviceLegs.isEmpty)
    }

    // MARK: - Router outcomes

    func testRouterPaysTheLnurlEndpointItPicksFromSpending() throws {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: false)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20, source: .spending, lightningSpendableSats: 5000, onchainSpendableSats: 0,
                serviceLegs: []
            ),
            network: .regtest
        )

        XCTAssertEqual(picked, .direct(endpoint: lightning))
    }

    func testRouterPaysTheOnchainEndpointItPicksFromSavings() throws {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: false)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20000, source: .savings, lightningSpendableSats: 0, onchainSpendableSats: 90000,
                serviceLegs: []
            ),
            network: .regtest
        )

        XCTAssertEqual(picked, .direct(endpoint: onchain))
    }

    func testRouterTakesTheSparkLegToAnOnchainOnlyContactFromSpending() throws {
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        let leg = sparkLeg(amountSats: 20000, feeSats: 300)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20000, source: .spending, lightningSpendableSats: 50000, onchainSpendableSats: 0,
                serviceLegs: [leg]
            ),
            network: .regtest
        )

        XCTAssertEqual(picked, .service(leg: leg))
        var routed = route
        routed.serviceLeg = leg
        XCTAssertEqual(routed.totalFeeSat, 300)
        XCTAssertEqual(routed.deliveredSat, 20000)
    }

    func testRouterFindsNoneWithoutABalanceThatReachesTheContact() throws {
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: false)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20000, source: .savings, lightningSpendableSats: 0, onchainSpendableSats: 5000,
                serviceLegs: []
            ),
            network: .regtest
        )

        guard case .none = picked else { return XCTFail("Expected no route, got \(picked)") }
        XCTAssertTrue(PaykitRouteService.isBalanceShort(amountSats: 20000, lightningSpendableSats: 0, onchainSpendableSats: 5000))
        XCTAssertFalse(PaykitRouteService.isBalanceShort(amountSats: 20000, lightningSpendableSats: 0, onchainSpendableSats: 90000))
    }

    // MARK: - Spark leg offer

    func testSparkLegIsOfferedForAnOnchainContactLightningCantPay() {
        let onchainOnly = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.regtestOnchainP2wpkh, onchain.value)]
        )

        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: true, canPayDirectly: false)?.offersSparkLeg,
            true
        )
        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: false, canPayDirectly: false)?.offersSparkLeg,
            false
        )
        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: true, canPayDirectly: true)?.offersSparkLeg,
            false
        )
        let usdtOnly = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [
            Self.endpoint(.usdtArbitrum, "0x0000000000000000000000000000000000000001"),
        ])
        XCTAssertNil(PaykitRouteService.routeUi(for: usdtOnly, canRouteThroughSpark: true, canPayDirectly: false))
    }

    // MARK: - Contact withdrawal journal

    func testJournaledWithdrawalMatchesOnlyItsOwnAttempt() {
        let other = Self.withdrawal(id: "other", to: "bcrt1qother", amountSats: 20000, timestamp: 1001)
        let earlier = Self.withdrawal(id: "earlier", to: onchain.value, amountSats: 20000, timestamp: 2000)
        let sent = Self.withdrawal(id: "sent", to: onchain.value, amountSats: 20000, timestamp: 1001)
        var pending = SparkContactWithdrawal(
            address: onchain.value,
            amountSats: 20000,
            contact: "contact",
            startedAt: 1000,
            earlierPaymentIds: SparkManager.withdrawalIds(to: onchain.value, amountSats: 20000, in: [other, earlier])
        )

        XCTAssertEqual(pending.earlierPaymentIds, ["earlier"])
        XCTAssertEqual(SparkManager.matchingWithdrawal(pending, in: [other, earlier, sent])?.id, "sent")
        XCTAssertNil(
            SparkManager.matchingWithdrawal(pending, in: [other, earlier]),
            "An earlier withdrawal to the same address is never this attempt"
        )

        pending.paymentId = "sent"
        XCTAssertNil(SparkManager.matchingWithdrawal(pending, in: [other, earlier]), "Once Spark returned the attempt, only that payment settles it")
        XCTAssertEqual(SparkManager.matchingWithdrawal(pending, in: [earlier, sent])?.id, "sent")
    }

    func testUnlistedWithdrawalIsDroppedOnlyAfterTheExpiry() {
        var pending = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000)
        let expiry = SparkManager.contactWithdrawalExpirySecs

        XCTAssertFalse(
            SparkManager.canCloseUnlisted(pending, now: 1001),
            "A sync right after the send may not list the withdrawal yet"
        )
        XCTAssertTrue(SparkManager.canCloseUnlisted(pending, now: 1000 + expiry))

        pending.paymentId = "sent"
        XCTAssertFalse(
            SparkManager.canCloseUnlisted(pending, now: 1000 + expiry * 10),
            "A withdrawal Spark returned went out and is never dropped as unsent"
        )
    }

    func testJournalStaysOpenUntilEveryLocalRecordIsSaved() async {
        let saved = await SparkManager.recordWithdrawalLocally(saveProof: { true }, saveActivity: { true }, saveTags: { true })
        XCTAssertTrue(saved)

        var tagsTried = false
        let activityFailed = await SparkManager.recordWithdrawalLocally(
            saveProof: { true },
            saveActivity: { false },
            saveTags: { tagsTried = true; return true }
        )
        XCTAssertFalse(activityFailed, "A failed activity write keeps the journal for a retry")
        XCTAssertFalse(tagsTried, "Tags wait for the activity they belong to")

        var activityTried = false
        let proofFailed = await SparkManager.recordWithdrawalLocally(
            saveProof: { false },
            saveActivity: { activityTried = true; return true },
            saveTags: { true }
        )
        XCTAssertFalse(proofFailed, "A proof that wasn't saved keeps the journal for a retry")
        XCTAssertTrue(activityTried, "The activity is still written when the proof save fails")

        let tagsFailed = await SparkManager.recordWithdrawalLocally(saveProof: { true }, saveActivity: { true }, saveTags: { false })
        XCTAssertFalse(tagsFailed)
    }

    func testUnsentWithdrawalKeepsItsJournalUntilTheProofIsReleased() async {
        snapshotAppDefaultsDomain()
        let request = SparkContactWithdrawal.PaykitRequest(
            id: PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "payee"),
            identity: "payer"
        )
        let pending = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000, request: request)
        SparkManager.pendingContactWithdrawal = pending

        var failedAllowances: [SparkContactWithdrawal.PaykitRequest] = []
        await SparkManager.closeUnsentWithdrawal(pending, releaseProof: { _ in false }, failAllowance: { failedAllowances.append($0) })
        XCTAssertEqual(SparkManager.pendingContactWithdrawal, pending, "A proof that wasn't released keeps the journal, so the next sync retries it")
        XCTAssertEqual(failedAllowances, [], "The attempt stays unknown while the journal is still open")

        var released: SparkContactWithdrawal.PaykitRequest?
        await SparkManager.closeUnsentWithdrawal(
            pending,
            releaseProof: { released = $0; return true },
            failAllowance: { failedAllowances.append($0) }
        )
        XCTAssertEqual(released, request)
        XCTAssertEqual(failedAllowances, [request], "An unsent withdrawal fails its allowance attempt, so the ledger lets the request be paid again")
        XCTAssertNil(SparkManager.pendingContactWithdrawal)
    }

    func testLegReportsItsAllowanceAttemptWithTheSendsOutcome() async {
        struct Refused: Error {}
        struct Lost: Error {}
        var events: [String] = []
        func pay(
            authorize: @escaping () async throws -> Void = {},
            send: @escaping (() async throws -> Void) async throws -> String
        ) async -> String? {
            try? await PaykitRouteService.payReportingAllowance(
                beginAllowance: { events.append("begin"); return "attempt" },
                authorize: { events.append("authorize"); try await authorize() },
                markSending: { events.append("sending \($0)") },
                finishAllowance: { events.append("finish \($0) \($1) \($2 ?? "-")") },
                pay: send
            )
        }

        let txid = await pay { beforeSend in try await beforeSend(); return "txid" }
        XCTAssertEqual(txid, "txid")
        XCTAssertEqual(events, ["begin", "authorize", "sending attempt", "finish attempt succeeded txid"])

        events = []
        _ = await pay(authorize: { throw Refused() }) { beforeSend in
            do { try await beforeSend() } catch { throw SparkWithdrawalNotSent(underlying: error) }
            return "txid"
        }
        XCTAssertEqual(events, ["begin", "authorize", "finish attempt failed -"], "A send Spark refused paid nothing")

        events = []
        _ = await pay { beforeSend in
            try await beforeSend()
            throw SparkWithdrawalNotSent(underlying: Refused())
        }
        XCTAssertEqual(
            events,
            ["begin", "authorize", "sending attempt", "finish attempt failed -"],
            "A withdrawal Spark returned as failed paid nothing either"
        )

        events = []
        _ = await pay { beforeSend in try await beforeSend(); throw Lost() }
        XCTAssertEqual(
            events,
            ["begin", "authorize", "sending attempt", "finish attempt unknown -"],
            "A send that may have gone out stays unknown until recovery settles it"
        )
    }

    func testAWithdrawalSparkReturnsAsFailedEndsAsARefusal() throws {
        let sent = Self.withdrawal(id: "sent", to: onchain.value, amountSats: 20000, timestamp: 1001)
        XCTAssertEqual(try SparkManager.sentWithdrawalId(sent), "tx-sent")

        var failed = sent
        failed.status = .failed
        XCTAssertThrowsError(try SparkManager.sentWithdrawalId(failed), "A failed withdrawal paid nothing, so it never shows success") {
            XCTAssertTrue($0 is SparkWithdrawalNotSent, "A refusal releases the request's proof, private list and allowance attempt")
        }
    }

    @MainActor
    func testAClosedJournalTellsThePendingScreenHowItsWithdrawalEnded() async {
        snapshotAppDefaultsDomain()
        let request = SparkContactWithdrawal.PaykitRequest(
            id: PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "payee"),
            identity: "payer"
        )
        let pending = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000, request: request)
        SparkManager.pendingContactWithdrawal = pending
        var resolutions: [SparkContactWithdrawalResolution] = []
        let subscription = SparkManager.contactWithdrawalResolutionPublisher.sink { resolutions.append($0) }
        defer { subscription.cancel() }

        await SparkManager.closeUnsentWithdrawal(pending, releaseProof: { _ in true }, failAllowance: { _ in })

        let unsent = SparkContactWithdrawalResolution(attempt: pending.attempt, txId: nil)
        XCTAssertEqual(resolutions, [unsent])
        XCTAssertEqual(SparkManager.lastContactWithdrawalResolution, unsent, "A screen that opens later still learns it")
        guard case .failure = SendPendingScreen.sparkWithdrawalRoute(for: unsent, attempt: pending.attempt) else {
            return XCTFail("A withdrawal that never went out can be tried again")
        }
        XCTAssertEqual(
            SendPendingScreen.sparkWithdrawalRoute(
                for: SparkContactWithdrawalResolution(attempt: pending.attempt, txId: "txid"),
                attempt: pending.attempt
            ),
            .success(paymentId: "txid")
        )
        let other = SparkWithdrawalAttempt(address: onchain.value, amountSats: 30000, requestId: request.id)
        XCTAssertNil(SendPendingScreen.sparkWithdrawalRoute(for: unsent, attempt: other), "Another withdrawal's close leaves the screen")
    }

    @MainActor
    func testAWithdrawalsJournalIsWrittenBeforeItsProofStarts() async {
        struct Refused: Error {}
        var steps: [String] = []

        try? await SparkManager.startJournaledWithdrawal(
            writeJournal: { steps.append("journal") },
            beforeSend: { steps.append("proof started") },
            closeUnsent: { steps.append("closed") }
        )
        XCTAssertEqual(steps, ["journal", "proof started"], "A kill after the proof starts leaves a journal that releases it")

        steps = []
        do {
            try await SparkManager.startJournaledWithdrawal(
                writeJournal: { steps.append("journal") },
                beforeSend: { steps.append("proof started"); throw Refused() },
                closeUnsent: { steps.append("closed") }
            )
            XCTFail("A refusal before the send must reach the caller")
        } catch {
            XCTAssertTrue(error is SparkWithdrawalNotSent)
        }
        XCTAssertEqual(steps, ["journal", "proof started", "closed"], "A refusal closes the journal, releasing what it started")
    }

    @MainActor
    func testARouteThatReturnsAfterItsPaymentChangedNeverLandsOnTheNextOne() async {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        let contactA = ContactPaymentContext(publicKey: "contacta", privatePaymentContext: nil, endpoints: [])
        let contactB = ContactPaymentContext(publicKey: "contactb", privatePaymentContext: nil, endpoints: [])
        let routeA = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        let routeB = PaykitRouteUi(endpoints: [lightning], offersSparkLeg: false)
        app.contactPaymentContext = contactA
        app.paykitRoute = routeA

        let outcome = await app.routeContactPayment(
            routeA,
            amountSats: 20000,
            source: .spending,
            lightningSpendableSats: 50000,
            onchainSpendableSats: 0,
            request: nil
        ) { _, _, _, _, _ in
            // Contact A's sheet is dismissed and contact B's opens while Spark quotes A's leg.
            app.contactPaymentContext = contactB
            app.paykitRoute = routeB
            return .service(leg: self.sparkLeg(amountSats: 20000, feeSats: 300))
        }

        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(app.paykitRoute, routeB, "contact A's leg must never pay contact B")
    }

    @MainActor
    func testAPendingSparkSendNeverAdoptsTheNodesOnchainAttempt() {
        let attempt = SparkWithdrawalAttempt(address: onchain.value, amountSats: 20000, requestId: nil)

        XCTAssertFalse(
            SendPendingScreen.readsNodeOnchainAttempts(sparkWithdrawal: attempt),
            "A Spark withdrawal never creates a node on-chain attempt, so an unrelated one must not show as this send"
        )
        XCTAssertTrue(SendPendingScreen.readsNodeOnchainAttempts(sparkWithdrawal: nil))
    }

    func testLegPreparesTheRequestBeforeItsProofIsStarted() async throws {
        var steps: [String] = []
        let identity = try await PaykitRouteService.startLegRequestProof(
            prepareProof: { steps.append("proof") },
            prepareRequest: { steps.append("request") },
            paymentIdentity: { steps.append("identity"); return "payer" },
            cancelProof: { steps.append("cancel") },
            releasePaymentList: { steps.append("release") }
        )

        XCTAssertEqual(identity, "payer")
        XCTAssertEqual(steps, ["proof", "request", "identity"], "The request is approved before Spark's payment check")
    }

    func testLegThatFailsBeforeSendingFreesTheRequest() async {
        struct Refused: Error {}
        for failing in ["proof", "request"] {
            var steps: [String] = []
            do {
                _ = try await PaykitRouteService.startLegRequestProof(
                    prepareProof: {
                        if failing == "proof" {
                            throw Refused()
                        }
                    },
                    prepareRequest: {
                        if failing == "request" {
                            throw Refused()
                        }
                    },
                    paymentIdentity: { "payer" },
                    cancelProof: { steps.append("cancel") },
                    releasePaymentList: { steps.append("release") }
                )
                XCTFail("\(failing) must fail the leg")
            } catch {}

            XCTAssertEqual(steps, failing == "proof" ? ["release"] : ["cancel", "release"], failing)
        }
    }

    func testSourceSwitchOnConfirmReroutesOnlyWhenTheLegNoLongerFits() throws {
        let context = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.regtestOnchainP2wpkh, onchain.value)]
        )
        let offered = try XCTUnwrap(PaykitRouteService.routeUi(for: context, canRouteThroughSpark: true, canPayDirectly: false))
        var routed = offered
        routed.serviceLeg = sparkLeg(amountSats: 20000, feeSats: 2190)

        XCTAssertTrue(SendConfirmationView.sourceSwitchNeedsReroute(route: routed, walletType: .onchain, hasLightningPayment: false))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: routed, walletType: .lightning, hasLightningPayment: false))
        XCTAssertTrue(SendConfirmationView.sourceSwitchNeedsReroute(route: offered, walletType: .lightning, hasLightningPayment: false))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: offered, walletType: .lightning, hasLightningPayment: true))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: offered, walletType: .onchain, hasLightningPayment: false))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: nil, walletType: .onchain, hasLightningPayment: false))
    }

    func testARefusedRerouteOnConfirmKeepsTheSwipeOffUntilAnotherSourceIsPicked() {
        let refused = SendConfirmationView.refusedRouteSource(after: .refused, on: .lightning, previous: nil)

        XCTAssertEqual(refused, .lightning)
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .lightning,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5,
            isRouteRefused: refused == .lightning
        ), "a refused route must keep the swipe off, so no private list is consumed for it")
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5,
            isRouteRefused: refused == .onchain
        ), "switching back to Savings pays the contact again")
        XCTAssertNil(SendConfirmationView.refusedRouteSource(after: .leg, on: .lightning, previous: refused))
    }

    func testALateRerouteOutcomeKeepsAnotherSourcesRefusal() {
        XCTAssertEqual(SendConfirmationView.refusedRouteSource(after: .direct, on: .onchain, previous: .lightning), .lightning)
        XCTAssertEqual(SendConfirmationView.refusedRouteSource(after: .refused, on: .onchain, previous: .lightning), .onchain)
    }

    func testOnchainRequestStartsOnSpendingWhenSavingsCantCoverIt() {
        // Savings 5,000 can't cover a 20,000 request, so Spending (Spark 50,000) pays it through the leg.
        XCTAssertTrue(SendConfirmationView.requestStartsOnSpending(savingsSendableSats: 5000, amountSats: 20000, offersSparkLeg: true))
        XCTAssertFalse(SendConfirmationView.requestStartsOnSpending(savingsSendableSats: 48000, amountSats: 20000, offersSparkLeg: true))
        XCTAssertFalse(
            SendConfirmationView.requestStartsOnSpending(savingsSendableSats: 5000, amountSats: 20000, offersSparkLeg: false),
            "Without a Spark leg the request stays on Savings"
        )
    }

    func testRefusalWhileAnOlderJournalIsOpenReleasesThisCallsProof() {
        struct Refused: Error {}
        let older = SparkContactWithdrawal.PaykitRequest(
            id: PaykitPaymentRequest.ID(paymentRequestId: "older", counterparty: "payee"),
            identity: "payer"
        )
        let this = SparkContactWithdrawal.PaykitRequest(
            id: PaykitPaymentRequest.ID(paymentRequestId: "this", counterparty: "payee"),
            identity: "payer"
        )
        let notSent = SparkWithdrawalNotSent(underlying: Refused())

        XCTAssertTrue(
            PaykitRouteService.legFailureReleasesProof(notSent, openJournalRequest: older, proofRequest: this),
            "An older journal still open must not keep a refused send's proof started"
        )
        XCTAssertTrue(PaykitRouteService.legFailureReleasesProof(notSent, openJournalRequest: nil, proofRequest: this))
        XCTAssertFalse(
            PaykitRouteService.legFailureReleasesProof(notSent, openJournalRequest: this, proofRequest: this),
            "An earlier attempt of the same request still owns its proof"
        )
        XCTAssertFalse(
            PaykitRouteService.legFailureReleasesProof(Refused(), openJournalRequest: this, proofRequest: this),
            "A failure once Spark's send started is settled by the journal"
        )
    }

    func testSparkLegDebitsTheL1BroadcastFeeToo() {
        let fee = SendOnchainSpeedFeeQuote(userFeeSat: 750, l1BroadcastFeeSat: 1440)

        XCTAssertEqual(SparkManager.withdrawalDebitSats(amountSats: 2000, fee: fee), 4190, "Confirm and the fee check use 2,190, not 750")
        XCTAssertThrowsError(try SparkManager.checkWithdrawalFee(2190, shownFeeSats: 750))
    }

    func testContactWithdrawalStaysASendNotATransfer() {
        let toContact = Self.withdrawal(id: "contact", to: onchain.value, amountSats: 20000, timestamp: 1)
        let toSavings = Self.withdrawal(id: "savings", to: "bcrt1qsavings", amountSats: 5000, timestamp: 1)

        let transfers = SparkManager.savingsTransferTxIds(unclaimed: [], payments: [toContact, toSavings], contactWithdrawals: ["tx-contact"])

        XCTAssertEqual(transfers, ["tx-savings"])
    }

    func testSparkScreenWithdrawalsLeaveOutContactPayments() {
        let saved = SparkManager.contactWithdrawalTxIds
        defer { SparkManager.contactWithdrawalTxIds = saved }
        SparkManager.contactWithdrawalTxIds = ["tx-contact"]
        let toContact = Self.withdrawal(id: "contact", to: onchain.value, amountSats: 20000, timestamp: 1)
        let toSavings = Self.withdrawal(id: "savings", to: "bcrt1qsavings", amountSats: 5000, timestamp: 1)

        XCTAssertEqual(
            SparkManager.withdrawals([toContact, toSavings]).map(\.txid),
            ["tx-savings"],
            "A contact payment is not a transfer to savings"
        )
    }

    private static func endpoint(_ methodId: PublicPaykitService.MethodId, _ value: String) -> PublicPaykitService.Endpoint {
        PublicPaykitService.Endpoint(methodId: methodId, value: value, min: nil, max: nil, rawPayload: value)
    }

    private static func withdrawal(id: String, to address: String, amountSats: UInt64, timestamp: UInt64) -> Payment {
        Payment(
            id: id,
            paymentType: .send,
            status: .completed,
            amount: U128(amountSats),
            fees: 300,
            timestamp: timestamp,
            method: .withdraw,
            details: .withdraw(txId: "tx-\(id)", vout: 0, destinationAddress: address),
            conversionDetails: nil
        )
    }
}
