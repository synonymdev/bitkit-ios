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

    func testSparkLegIsOfferedForAnOnchainContactWhileSparkCanRoute() {
        let onchainOnly = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.regtestOnchainP2wpkh, onchain.value)]
        )

        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: true)?.offersSparkLeg,
            true
        )
        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: false)?.offersSparkLeg,
            false
        )
        let usdtOnly = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [
            Self.endpoint(.usdtArbitrum, "0x0000000000000000000000000000000000000001"),
        ])
        XCTAssertNil(PaykitRouteService.routeUi(for: usdtOnly, canRouteThroughSpark: true))
    }

    func testASparkWithdrawalIsWeighedAgainstSparksBalanceNotTheLightningLimit() {
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        var quoted = route
        quoted.serviceLeg = sparkLeg(amountSats: 999_000, feeSats: 500)

        // Lightning's limit of 997,506 sats never caps a withdrawal from Spark's 1,000,000.
        XCTAssertEqual(
            PaykitRouteService.sparkWithdrawalValidity(route: route, amountSats: 999_000, sparkBalanceSats: 1_000_000),
            true,
            "continue asks spark for a quote"
        )
        XCTAssertEqual(
            PaykitRouteService.sparkWithdrawalValidity(route: quoted, amountSats: 999_000, sparkBalanceSats: 1_000_000),
            true,
            "the quoted debit fits spark's balance"
        )
        XCTAssertEqual(
            PaykitRouteService.sparkWithdrawalValidity(route: quoted, amountSats: 999_000, sparkBalanceSats: 999_499),
            false,
            "a debit past spark's balance can't be sent"
        )
        XCTAssertNil(
            PaykitRouteService.sparkWithdrawalValidity(route: route, amountSats: 1_000_001, sparkBalanceSats: 1_000_000),
            "past spark's balance, lightning's limit decides"
        )
        XCTAssertNil(
            PaykitRouteService.sparkWithdrawalValidity(
                route: PaykitRouteUi(endpoints: [onchain], offersSparkLeg: false),
                amountSats: 999_000,
                sparkBalanceSats: 1_000_000
            ),
            "without a spark leg, lightning's limit decides"
        )
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

    func testAFailedWithdrawalStaysOpenAfterASyncThatNeverReachedSpark() async {
        var allowedClears: [Bool] = []
        // The sync call returns, but Spark keeps its failed sync in `lastSyncError`, so it never synced after the failure.
        await SparkManager.settleAfterFailedWithdrawal(
            failedAt: 1000,
            syncWallet: {},
            hasSynced: { _ in false },
            settle: { allowedClears.append($0) }
        )
        XCTAssertEqual(allowedClears, [false], "A sync that never reached Spark can't show the withdrawal was never sent")

        var syncedAfter: UInt64?
        await SparkManager.settleAfterFailedWithdrawal(
            failedAt: 1000,
            syncWallet: {},
            hasSynced: { syncedAfter = $0; return true },
            settle: { allowedClears.append($0) }
        )
        XCTAssertEqual(syncedAfter, 1000)
        XCTAssertEqual(allowedClears, [false, true])

        // Spark's `.synced` event also follows a sync that never reached it.
        await SparkManager.settleAfterSync(since: 900, hasSynced: { syncedAfter = $0; return false }, settle: { allowedClears.append($0) })
        XCTAssertEqual(syncedAfter, 900)
        XCTAssertEqual(allowedClears, [false, true, false], "A synced event alone can't show the withdrawal was never sent")
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
        await SparkManager.closeUnsentWithdrawal(
            pending,
            releaseProof: { _, _ in .failed },
            failAllowance: { failedAllowances.append($0); return true }
        )
        XCTAssertEqual(SparkManager.pendingContactWithdrawal, pending, "A proof that wasn't released keeps the journal, so the next sync retries it")
        XCTAssertEqual(failedAllowances, [], "The attempt stays unknown while the journal is still open")

        var released: SparkContactWithdrawal.PaykitRequest?
        await SparkManager.closeUnsentWithdrawal(
            pending,
            releaseProof: { request, failAllowance in
                released = request
                return await failAllowance() ? .released : .failed
            },
            failAllowance: { failedAllowances.append($0); return true }
        )
        XCTAssertEqual(released, request)
        XCTAssertEqual(failedAllowances, [request], "An unsent withdrawal fails its allowance attempt, so the ledger lets the request be paid again")
        XCTAssertNil(SparkManager.pendingContactWithdrawal)

        // A kill before the proof started leaves no Spark attempt, so a direct send's attempt for the request stays.
        SparkManager.pendingContactWithdrawal = pending
        failedAllowances = []
        await SparkManager.closeUnsentWithdrawal(
            pending,
            releaseProof: { _, _ in .nothingStarted },
            failAllowance: { failedAllowances.append($0); return true }
        )
        XCTAssertEqual(failedAllowances, [], "Only the Spark withdrawal's own allowance attempt fails")
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

        await SparkManager.closeUnsentWithdrawal(pending, releaseProof: { _, _ in .released }, failAllowance: { _ in true })

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
    func testAWithdrawalWhoseQuoteExpiresBeforeItSendsNeverLeaves() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var steps: [String] = []
        do {
            try await SparkManager.startJournaledWithdrawal(
                writeJournal: { steps.append("journal") },
                beforeSend: {
                    // The quote expires while the allowance and the request are checked.
                    now = now.addingTimeInterval(120)
                    steps.append("proof started")
                },
                closeUnsent: { steps.append("closed") },
                paymentDeadline: PaykitPreciseInstant(date: now.addingTimeInterval(60)),
                now: { now }
            )
            XCTFail("An expired quote must stop the send")
        } catch let error as SparkWithdrawalNotSent {
            XCTAssertEqual(error.underlying as? PaykitPaymentRequestError, .requestExpired)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(steps, ["journal", "proof started", "closed"], "The refusal closes the journal, releasing the started proof")
    }

    func testAPendingWithdrawalStaysOpenUntilSparkAcceptsItsPayout() {
        XCTAssertEqual(
            SparkManager.settlement(of: .pending),
            .wait,
            "Spark keeps a withdrawal pending until the provider accepts its payout, and it can still fail"
        )
        XCTAssertEqual(SparkManager.settlement(of: .completed), .record)
        XCTAssertEqual(SparkManager.settlement(of: .failed), .closeUnsent)
    }

    @MainActor
    func testADefiniteSparkRefusalClosesTheWithdrawalAtOnce() async {
        var steps: [String] = []
        let refused = await SparkManager.withdrawalSendFailure(
            SdkError.InsufficientFunds(tokenIdentifier: nil),
            closeUnsent: { steps.append("closed") },
            settleLater: { steps.append("settle later") }
        )
        XCTAssertTrue(refused is SparkWithdrawalNotSent, "Spark picks leaves before anything reaches the operators")
        XCTAssertEqual(steps, ["closed"], "A refusal releases the journal at once instead of after the expiry")

        steps = []
        let feeRose = await SparkManager.withdrawalSendFailure(
            SdkError.InvalidInput(
                "The onchain fee rose to 900 sats at the slowest speed, above the 500 sats quoted for this payment. Please re-prepare the payment."
            ),
            closeUnsent: { steps.append("closed") },
            settleLater: { steps.append("settle later") }
        )
        XCTAssertTrue(feeRose is SparkWithdrawalNotSent, "Spark checks a refreshed quote's fee before it withdraws")
        XCTAssertEqual(steps, ["closed"])

        steps = []
        let unknown = await SparkManager.withdrawalSendFailure(
            SdkError.SparkError("operators"),
            closeUnsent: { steps.append("closed") },
            settleLater: { steps.append("settle later") }
        )
        XCTAssertFalse(unknown is SparkWithdrawalNotSent)
        XCTAssertEqual(steps, ["settle later"], "An outcome that may have sent it settles from the sync after it")
    }

    @MainActor
    func testASecondContactWithdrawalIsRefusedWhileTheFirstPrepares() throws {
        snapshotAppDefaultsDomain()
        SparkManager.pendingContactWithdrawal = nil
        let spark = SparkManager.shared
        try spark.claimContactWithdrawal()
        defer { spark.releaseContactWithdrawalClaim() }

        XCTAssertThrowsError(try spark.claimContactWithdrawal(), "A second send must never overwrite the first one's journal")
        spark.releaseContactWithdrawalClaim()
        XCTAssertNoThrow(try spark.claimContactWithdrawal())
    }

    func testAnUnfundedRequestReachesConfirmWhileSparkCanCarryIt() throws {
        let context = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.regtestOnchainP2wpkh, onchain.value)]
        )
        let offered = try XCTUnwrap(PaykitRouteService.routeUi(for: context, canRouteThroughSpark: true))
        let direct = try XCTUnwrap(PaykitRouteService.routeUi(for: context, canRouteThroughSpark: false))

        XCTAssertFalse(SendSheet.rejectsUnfundedOnchainRequest(route: offered), "Confirm routes it from Spending through Spark")
        XCTAssertTrue(SendSheet.rejectsUnfundedOnchainRequest(route: direct))
        XCTAssertTrue(SendSheet.rejectsUnfundedOnchainRequest(route: nil))
    }

    @MainActor
    func testAHardwareWalletPickOnAmountDropsTheSparkLeg() {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        var routed = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        routed.serviceLeg = sparkLeg(amountSats: 20000, feeSats: 2190)
        app.paykitRoute = routed
        app.selectedWalletToPayFrom = .lightning

        SendAmountView.selectWallet(of: .hardware(walletId: "trezor"), app: app)

        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
        XCTAssertNil(app.paykitRoute?.serviceLeg, "Confirm must never describe the Spark leg for a hardware wallet's send")
        XCTAssertEqual(app.paykitRoute?.endpoints, routed.endpoints)

        app.paykitRoute = routed
        SendAmountView.selectWallet(of: .savings, app: app)
        XCTAssertEqual(app.paykitRoute, routed, "Savings asks the router again on Continue")
    }

    func testAnLnurlOutsideItsLimitsLeavesTheSparkLegToTheRouter() {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: true, lnurl: lnurlData(minSendableMsats: 5_000_000))
        let leg = sparkLeg(amountSats: 1000, feeSats: 2190)

        let below = PaykitRouteService.request(
            route: route,
            amountSats: 1000,
            source: .spending,
            lightningSpendableSats: 4000,
            onchainSpendableSats: 0,
            serviceLegs: [leg]
        )
        XCTAssertEqual(below.contactEndpoints, [onchain], "An LNURL that refuses the amount must never win over the Spark leg")

        let within = PaykitRouteService.request(
            route: route,
            amountSats: 6000,
            source: .spending,
            lightningSpendableSats: 10000,
            onchainSpendableSats: 0,
            serviceLegs: []
        )
        XCTAssertEqual(within.contactEndpoints, [lightning, onchain])
    }

    @MainActor
    func testTheRouterIsAskedWithTheLnurlItsLimitsComeFrom() async {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: true)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.lnurlPayData = lnurlData(minSendableMsats: 5_000_000)
        app.selectedWalletToPayFrom = .lightning
        var asked: PaykitRouteUi?

        _ = await app.routeContactPayment(
            route,
            amountSats: 1000,
            source: .spending,
            lightningSpendableSats: 4000,
            onchainSpendableSats: 0,
            request: nil
        ) { route, _, _, _, _ in
            asked = route
            return .service(leg: self.sparkLeg(amountSats: 1000, feeSats: 2190))
        }

        XCTAssertEqual(asked?.lnurl, app.lnurlPayData, "The router must see the LNURL's limits")
    }

    @MainActor
    func testAContactWhoseLnurlMinimumLightningPaysStillOffersSparkPastTheLightningLimit() async throws {
        snapshotAppDefaultsDomain()
        let lnurl = LnurlPayData(
            uri: lightning.value,
            callback: "https://example.com/pay",
            minSendable: 1_000_000,
            maxSendable: 2_000_000_000,
            metadataStr: "[]",
            commentAllowed: nil,
            allowsNostr: false,
            nostrPubkey: nil
        )
        let address = onchain.value
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 997_506,
                        hasChannels: false,
                        hasUsableChannels: false
                    )
                },
                canSendLightning: { $0 <= 997_506 },
                decodeInvoice: { value in
                    value == address
                        ? .onChain(invoice: OnChainInvoice(address: address, amountSatoshis: 0, label: nil, message: nil, params: nil))
                        : .lnurlPay(data: lnurl)
                },
                canRouteThroughSpark: { true }
            )
        )
        let context = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [
                Self.endpoint(.bitcoinLightningLnurl, lightning.value),
                Self.endpoint(.regtestOnchainP2wpkh, address),
                Self.endpoint(.usdtArbitrum, "0x1111111111111111111111111111111111111111"),
            ]
        )
        XCTAssertTrue(app.claimContactPaymentContext(context))

        try await app.handleScannedData(lightning.value, claimedContactPaymentContext: context)

        XCTAssertEqual(app.lnurlPayData, lnurl)
        XCTAssertEqual(
            app.paykitRoute?.offersSparkLeg,
            true,
            "Lightning pays the LNURL's minimum, but a 999,000-sat payment past its 997,506 limit still needs Spark"
        )
    }

    func testALightningPayableContactRoutesDirectWithoutASparkQuote() async throws {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: true)
        var quotes = 0

        let direct = try await PaykitRouteService.route(
            route, amountSats: 2000, source: .spending, lightningSpendableSats: 50000, onchainSpendableSats: 0
        ) { _, _ in quotes += 1; return [] }
        XCTAssertEqual(direct, .direct(endpoint: lightning))
        XCTAssertEqual(quotes, 0, "Spark's quote is never fetched for a payment Lightning makes")

        let leg = sparkLeg(amountSats: 60000, feeSats: 300)
        let routed = try await PaykitRouteService.route(
            route, amountSats: 60000, source: .spending, lightningSpendableSats: 50000, onchainSpendableSats: 0
        ) { endpoints, amountSats in
            quotes += 1
            XCTAssertEqual(endpoints, [self.onchain])
            XCTAssertEqual(amountSats, 60000)
            return [leg]
        }
        XCTAssertEqual(routed, .service(leg: leg), "An amount past Lightning's limit still takes the quoted Spark leg")
        XCTAssertEqual(quotes, 1)
    }

    @MainActor
    func testANoneRouteNamesTheLnurlLimitTheAmountMissed() async {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        defer { ToastWindowManager.shared.hideToast() }
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.lnurlPayData = lnurlData(minSendableMsats: 1_000_000)
        app.selectedWalletToPayFrom = .lightning

        let outcome = await app.routeContactPayment(
            PaykitRouteUi(endpoints: [lightning], offersSparkLeg: false),
            amountSats: 500,
            source: .spending,
            lightningSpendableSats: 50000,
            onchainSpendableSats: 0,
            request: nil
        )

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(
            ToastWindowManager.shared.currentToast?.accessibilityIdentifier,
            "LnurlPayAmountTooLowToast",
            "A contact with a working LNURL is payable, only not at this amount"
        )
    }

    @MainActor
    func testASparkLegItsFeeTakesPastTheBalanceShowsTheBalanceCopy() async {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        defer { ToastWindowManager.shared.hideToast() }
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.selectedWalletToPayFrom = .lightning
        let fee = SendOnchainSpeedFeeQuote(userFeeSat: 750, l1BroadcastFeeSat: 1440)

        let outcome = await app.routeContactPayment(
            PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true),
            amountSats: 9000,
            source: .spending,
            lightningSpendableSats: 10000,
            onchainSpendableSats: 0,
            request: nil
        ) { route, amountSats, source, lightningSats, onchainSats in
            try await PaykitRouteService.route(
                route, amountSats: amountSats, source: source, lightningSpendableSats: lightningSats, onchainSpendableSats: onchainSats
            ) { endpoints, amountSats in
                try await PaykitRouteService.sparkLegs(to: endpoints, amountSats: amountSats) { endpoint, amountSats in
                    try SparkManager.withdrawalRouteLeg(
                        endpoint: endpoint, amountSats: amountSats, fee: fee, validUntilUnix: 0, balanceSats: 10000
                    )
                }
            }
        }

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(
            ToastWindowManager.shared.currentToast?.accessibilityIdentifier,
            "PaykitRouteBalanceToast",
            "Spark holds 10,000 but the 9,000 withdrawal takes 11,190 with its fee, so the balance is what falls short"
        )
    }

    @MainActor
    func testAPendingWithdrawalSendIsHeldUntilItsJournalSettles() {
        var pending = Self.withdrawal(id: "sent", to: onchain.value, amountSats: 20000, timestamp: 1001)
        pending.status = .pending

        XCTAssertThrowsError(try SparkManager.sentWithdrawalId(pending), "A pending withdrawal can still fail, so it never shows success") {
            XCTAssertFalse($0 is SparkWithdrawalNotSent, "It may still pay, so its proof and allowance attempt stay")
            XCTAssertEqual(
                SendConfirmationView.serviceLegFailureRoute(
                    $0,
                    attempt: SparkWithdrawalAttempt(address: self.onchain.value, amountSats: 20000, requestId: nil),
                    routingCacheResetAttempted: false
                ),
                .sparkWithdrawalPending(SparkWithdrawalAttempt(address: self.onchain.value, amountSats: 20000, requestId: nil))
            )
        }
    }

    @MainActor
    func testAMixedBitcoinContactWithoutUsdtOpensOnAmountWithTheSparkLeg() async throws {
        snapshotAppDefaultsDomain()
        let lnurl = lnurlData(minSendableMsats: 5_000_000)
        let address = onchain.value
        let sheets = SheetViewModel()
        let app = AppViewModel(
            sheetViewModel: sheets,
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 10000,
                        hasChannels: false,
                        hasUsableChannels: false
                    )
                },
                canSendLightning: { $0 <= 10000 },
                decodeInvoice: { value in
                    value == address
                        ? .onChain(invoice: OnChainInvoice(address: address, amountSatoshis: 0, label: nil, message: nil, params: nil))
                        : .lnurlPay(data: lnurl)
                },
                canRouteThroughSpark: { true }
            )
        )
        let context = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.bitcoinLightningLnurl, lightning.value), Self.endpoint(.regtestOnchainP2wpkh, address)]
        )
        XCTAssertFalse(context.requiresAssetSelection)
        XCTAssertTrue(app.claimContactPaymentContext(context))

        try await app.handleScannedData(lightning.value, claimedContactPaymentContext: context)
        PaymentNavigationHelper.openPaymentSheet(
            app: app,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            settings: SettingsViewModel.shared,
            sheetViewModel: sheets
        )

        XCTAssertEqual(app.paykitRoute?.offersSparkLeg, true, "2,000 sats below the LNURL's 5,000 minimum can still go through Spark")
        XCTAssertEqual(app.scannedOnchainInvoice?.address, address)
        XCTAssertEqual(sheets.sendSheetItem?.initialRoute, .amount, "Amount picks the source, so the amount reaches the router")
    }

    private func lnurlData(minSendableMsats: UInt64) -> LnurlPayData {
        LnurlPayData(
            uri: lightning.value,
            callback: "https://example.com/pay",
            minSendable: minSendableMsats,
            maxSendable: 100_000_000,
            metadataStr: "[]",
            commentAllowed: nil,
            allowsNostr: false,
            nostrPubkey: nil
        )
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
    func testARouteThatReturnsAfterTheSourceChangedNeverRestoresIt() async {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.paykitRoute = route
        app.selectedWalletToPayFrom = .lightning

        let outcome = await app.routeContactPayment(
            route,
            amountSats: 20000,
            source: .spending,
            lightningSpendableSats: 50000,
            onchainSpendableSats: 0,
            request: nil
        ) { _, _, _, _, _ in
            // The user goes back to Savings while Spark quotes the Spending leg.
            app.selectedWalletToPayFrom = .onchain
            return .service(leg: self.sparkLeg(amountSats: 20000, feeSats: 300))
        }

        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain, "a superseded Spending quote must not take the source back")
        XCTAssertNil(app.paykitRoute?.serviceLeg)
    }

    @MainActor
    func testARouteSupersededByANewerOneIsDropped() async {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.paykitRoute = route
        app.selectedWalletToPayFrom = .lightning
        var newer: PaykitRouteOutcome?

        let older = await app.routeContactPayment(
            route,
            amountSats: 20000,
            source: .spending,
            lightningSpendableSats: 50000,
            onchainSpendableSats: 0,
            request: nil
        ) { _, _, _, _, _ in
            // A new amount asks the router again before the first quote returns.
            newer = await app.routeContactPayment(
                route,
                amountSats: 30000,
                source: .spending,
                lightningSpendableSats: 50000,
                onchainSpendableSats: 0,
                request: nil
            ) { _, _, _, _, _ in .service(leg: self.sparkLeg(amountSats: 30000, feeSats: 300)) }
            return .service(leg: self.sparkLeg(amountSats: 20000, feeSats: 300))
        }

        XCTAssertEqual(newer, .leg)
        XCTAssertEqual(older, .stale)
        XCTAssertEqual(app.paykitRoute?.serviceLeg?.deliveredSat, 30000, "the older amount's leg must not replace the newer one")
    }

    @MainActor
    func testADirectRerouteFromBolt11BackToLnurlPaysTheLnurl() async {
        let (app, route, bolt11, lnurl) = openLightningContact()

        let first = await routeDirectly(app, route, to: bolt11)
        XCTAssertEqual(first, .direct)
        XCTAssertNil(app.lnurlPayData)

        let second = await routeDirectly(app, app.paykitRoute ?? route, to: lnurl)
        XCTAssertEqual(second, .direct)
        XCTAssertEqual(app.lnurlPayData?.uri, lnurl.value, "the LNURL pick must pay the LNURL, not the skipped invoice")
        XCTAssertNil(app.scannedLightningInvoice)
    }

    @MainActor
    func testADirectRerouteFromLnurlBackToBolt11PaysTheInvoice() async {
        let (app, route, bolt11, lnurl) = openLightningContact()

        let first = await routeDirectly(app, route, to: lnurl)
        XCTAssertEqual(first, .direct)
        XCTAssertNil(app.scannedLightningInvoice, "the LNURL pick must not leave the invoice to pay")

        let second = await routeDirectly(app, app.paykitRoute ?? route, to: bolt11)
        XCTAssertEqual(second, .direct)
        XCTAssertEqual(app.scannedLightningInvoice?.bolt11, bolt11.value)
        XCTAssertNil(app.lnurlPayData)
    }

    @MainActor
    func testARerouteFromBolt11ToLnurlBelowItsMinimumShowsTheMinimumToast() async {
        let (app, route, bolt11, lnurl) = openLightningContact(lnurlMinSendableMsats: 1_000_000)
        defer { ToastWindowManager.shared.hideToast() }

        let first = await routeDirectly(app, route, to: bolt11)
        XCTAssertEqual(first, .direct)
        XCTAssertNil(app.lnurlPayData)

        let second = await routeDirectly(app, app.paykitRoute ?? route, to: lnurl, amountSats: 500)
        XCTAssertEqual(second, .direct)
        XCTAssertEqual(app.lnurlPayData?.uri, lnurl.value)
        XCTAssertFalse(app.validateRoutedLnurlAmount(amountSats: 500), "the restored LNURL's minimum must stop Confirm")
        let toast = ToastWindowManager.shared.currentToast
        XCTAssertEqual(toast?.accessibilityIdentifier, "LnurlPayAmountTooLowToast")
        XCTAssertEqual(toast?.title, t("wallet__lnurl_pay__error_min__title"))
        XCTAssertEqual(toast?.description, t(
            "wallet__lnurl_pay__error_min__description",
            variables: ["amount": CurrencyFormatter.formatSats(1000)]
        ))
    }

    @MainActor
    func testARerouteFromBolt11ToLnurlAboveItsMaximumShowsTheMaximumToast() async {
        let (app, route, bolt11, lnurl) = openLightningContact(lnurlMaxSendableMsats: 3_000_000)
        defer { ToastWindowManager.shared.hideToast() }

        let first = await routeDirectly(app, route, to: bolt11)
        XCTAssertEqual(first, .direct)
        XCTAssertNil(app.lnurlPayData)

        let second = await routeDirectly(app, app.paykitRoute ?? route, to: lnurl, amountSats: 4000)
        XCTAssertEqual(second, .direct)
        XCTAssertEqual(app.lnurlPayData?.uri, lnurl.value)
        XCTAssertFalse(app.validateRoutedLnurlAmount(amountSats: 4000), "the restored LNURL's maximum must stop Confirm")
        let toast = ToastWindowManager.shared.currentToast
        XCTAssertEqual(toast?.accessibilityIdentifier, "LnurlPayAmountTooHighToast")
        XCTAssertEqual(toast?.title, t("wallet__lnurl_pay__error_max__title"))
        XCTAssertEqual(toast?.description, t("wallet__lnurl_pay__error_max__description"))
    }

    @MainActor
    private func openLightningContact(
        lnurlMinSendableMsats: UInt64 = 1000,
        lnurlMaxSendableMsats: UInt64 = 100_000_000
    ) -> (AppViewModel, PaykitRouteUi, PaykitEndpoint, PaykitEndpoint) {
        snapshotAppDefaultsDomain()
        let app = AppViewModel()
        let bolt11 = PaykitEndpoint(
            methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            value: "lnbcrt1contactreroute"
        )
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: bolt11.value,
            paymentHash: Data(),
            amountSatoshis: 0,
            timestampSeconds: 1,
            expirySeconds: 3600,
            isExpired: false,
            description: nil,
            networkType: .regtest,
            payeeNodeId: nil
        )
        app.lnurlPayData = LnurlPayData(
            uri: lightning.value,
            callback: "https://example.com/pay",
            minSendable: lnurlMinSendableMsats,
            maxSendable: lnurlMaxSendableMsats,
            metadataStr: "[]",
            commentAllowed: nil,
            allowsNostr: false,
            nostrPubkey: nil
        )
        app.selectedWalletToPayFrom = .lightning
        return (app, PaykitRouteUi(endpoints: [bolt11, lightning], offersSparkLeg: false), bolt11, lightning)
    }

    @MainActor
    private func routeDirectly(
        _ app: AppViewModel,
        _ route: PaykitRouteUi,
        to endpoint: PaykitEndpoint,
        amountSats: UInt64 = 2000
    ) async -> PaykitRouteOutcome {
        await app.routeContactPayment(
            route,
            amountSats: amountSats,
            source: .spending,
            lightningSpendableSats: 50000,
            onchainSpendableSats: 0,
            request: nil
        ) { _, _, _, _, _ in .direct(endpoint: endpoint) }
    }

    @MainActor
    func testAStaleRecoveryNeverClearsANewerWithdrawalsJournal() async {
        snapshotAppDefaultsDomain()
        let older = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000)
        let newer = SparkContactWithdrawal(address: onchain.value, amountSats: 30000, contact: "contact", startedAt: 2000)
        // A recovery captured the older withdrawal; another one closed it and the newer withdrawal wrote its journal.
        SparkManager.pendingContactWithdrawal = newer

        await SparkManager.closeUnsentWithdrawal(older, releaseProof: { _, _ in .nothingStarted }, failAllowance: { _ in true })

        XCTAssertEqual(SparkManager.pendingContactWithdrawal, newer, "Losing the newer journal could pay it twice")
    }

    @MainActor
    func testAStaleCloseNeverTellsTheNewerWithdrawalsScreenItEnded() async {
        snapshotAppDefaultsDomain()
        let request = SparkContactWithdrawal.PaykitRequest(
            id: PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "payee"),
            identity: "payer"
        )
        // A retry of the same request: same address, amount and request, so both share one attempt.
        let older = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000, request: request)
        let newer = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 2000, request: request)
        XCTAssertEqual(older.attempt, newer.attempt)
        SparkManager.pendingContactWithdrawal = newer
        var resolutions: [SparkContactWithdrawalResolution] = []
        let subscription = SparkManager.contactWithdrawalResolutionPublisher.sink { resolutions.append($0) }
        defer { subscription.cancel() }

        await SparkManager.closeUnsentWithdrawal(older, releaseProof: { _, _ in .nothingStarted }, failAllowance: { _ in true })

        XCTAssertEqual(SparkManager.pendingContactWithdrawal, newer)
        XCTAssertEqual(resolutions, [], "An unsent resolution for the newer send's attempt would offer Try Again while it is in flight")
    }

    @MainActor
    func testAStaleCloseDuringARetryKeepsTheNewerProofAndAllowanceAttempt() async {
        snapshotAppDefaultsDomain()
        let request = SparkContactWithdrawal.PaykitRequest(
            id: PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "payee"),
            identity: "payer"
        )
        let older = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000, request: request)
        let newer = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 2000, request: request)
        SparkManager.pendingContactWithdrawal = newer
        var released: [SparkContactWithdrawal.PaykitRequest] = []
        var failedAllowances: [SparkContactWithdrawal.PaykitRequest] = []

        await SparkManager.closeUnsentWithdrawal(
            older,
            releaseProof: { request, failAllowance in
                released.append(request)
                return await failAllowance() ? .released : .failed
            },
            failAllowance: { failedAllowances.append($0); return true }
        )

        XCTAssertEqual(released, [], "The proof matches by request, so a stale close would release the retry's started proof")
        XCTAssertEqual(failedAllowances, [], "The retry's allowance attempt stays open while it is in flight")
        XCTAssertEqual(SparkManager.pendingContactWithdrawal, newer)
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
        let offered = try XCTUnwrap(PaykitRouteService.routeUi(for: context, canRouteThroughSpark: true))
        var routed = offered
        routed.serviceLeg = sparkLeg(amountSats: 20000, feeSats: 2190)

        XCTAssertTrue(SendConfirmationView.sourceSwitchNeedsReroute(route: routed, walletType: .onchain))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: routed, walletType: .lightning))
        XCTAssertTrue(SendConfirmationView.sourceSwitchNeedsReroute(route: offered, walletType: .lightning))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: offered, walletType: .onchain))
        XCTAssertFalse(SendConfirmationView.sourceSwitchNeedsReroute(route: nil, walletType: .onchain))
    }

    func testADirectLnurlPickOnConfirmPaysOnTheLnurlConfirm() {
        XCTAssertTrue(SendConfirmationView.reroutePaysLnurl(outcome: .direct, walletType: .lightning, hasInvoice: false, hasLnurl: true))
        XCTAssertFalse(SendConfirmationView.reroutePaysLnurl(outcome: .direct, walletType: .lightning, hasInvoice: true, hasLnurl: true))
        XCTAssertFalse(SendConfirmationView.reroutePaysLnurl(outcome: .leg, walletType: .lightning, hasInvoice: false, hasLnurl: true))
        XCTAssertFalse(SendConfirmationView.reroutePaysLnurl(outcome: .direct, walletType: .onchain, hasInvoice: false, hasLnurl: true))
    }

    /// A mixed contact paid directly from Savings keeps its decoded Lightning payment, so a switch to Spending must still
    /// ask the router: over Lightning's limit only a Spark withdrawal pays it.
    func testSourceSwitchToSpendingReroutesAMixedContactRoutedDirectFromSavings() {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: true)

        XCTAssertTrue(SendConfirmationView.sourceSwitchNeedsReroute(route: route, walletType: .lightning))
    }

    func testASparkRoutedConfirmCanMoveToAnotherSource() throws {
        let context = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.regtestOnchainP2wpkh, onchain.value)]
        )
        var routed = try XCTUnwrap(PaykitRouteService.routeUi(for: context, canRouteThroughSpark: true))
        routed.serviceLeg = sparkLeg(amountSats: 20000, feeSats: 2190)

        XCTAssertEqual(
            SendConfirmationView.fundingSources(hasLightningInvoice: false, hasOnchainInvoice: true, offersSparkLeg: true, hardwareWalletIds: ["hw"]),
            [.spending, .savings, .hardware(walletId: "hw")],
            "Confirm on a Spark leg still offers Savings and the hardware wallet"
        )
        // The router never runs for a hardware wallet, so its pick drops the leg for the on-chain send it signs.
        XCTAssertNil(SendConfirmationView.route(routed, afterSelecting: .hardware(walletId: "hw"))?.serviceLeg)
        XCTAssertEqual(SendConfirmationView.route(routed, afterSelecting: .hardware(walletId: "hw"))?.endpoints, routed.endpoints)
        // Savings and Spending ask the router again, which settles the leg.
        XCTAssertEqual(SendConfirmationView.route(routed, afterSelecting: .savings), routed)
        XCTAssertEqual(SendConfirmationView.route(routed, afterSelecting: .spending), routed)
        XCTAssertNil(SendConfirmationView.route(nil, afterSelecting: .hardware(walletId: "hw")))
    }

    func testTheFromControlStaysSwitchableOnASparkRoute() {
        let sources = SendConfirmationView.fundingSources(
            hasLightningInvoice: false,
            hasOnchainInvoice: true,
            offersSparkLeg: true,
            hardwareWalletIds: []
        )
        let canSwitch = SendConfirmationView.canSwitchFundingSource(hasRetainedHardwareRetry: false, fundingSources: sources)

        let control = SendConfirmationView.sparkRouteFromControl(canSwitchFundingSource: canSwitch)

        XCTAssertTrue(control.isSwitchable, "After picking Spark, FROM still moves a fixed request to Savings")
        XCTAssertEqual(control.titleKey, "wallet__spending__title")
        // A retained hardware retry pins the source, on a Spark route too.
        let pinned = SendConfirmationView.canSwitchFundingSource(hasRetainedHardwareRetry: true, fundingSources: sources)
        XCTAssertFalse(SendConfirmationView.sparkRouteFromControl(canSwitchFundingSource: pinned).isSwitchable)
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

    func testConfirmOffersSpendingWhileASparkLegCanCarryAnOnchainRequest() {
        // Savings covers the request, so its Confirm opens on Savings; Spending through Spark is still a source.
        XCTAssertEqual(
            SendConfirmationView.fundingSources(hasLightningInvoice: false, hasOnchainInvoice: true, offersSparkLeg: true, hardwareWalletIds: []),
            [.spending, .savings]
        )
        // Savings is short, so the request opens on Spending, which must be in the list to switch back to.
        XCTAssertEqual(
            SendConfirmationView.fundingSources(hasLightningInvoice: false, hasOnchainInvoice: true, offersSparkLeg: true, hardwareWalletIds: ["hw"]),
            [.spending, .savings, .hardware(walletId: "hw")]
        )
        XCTAssertEqual(
            SendConfirmationView.fundingSources(hasLightningInvoice: false, hasOnchainInvoice: true, offersSparkLeg: false, hardwareWalletIds: []),
            [.savings],
            "Without a Spark leg an on-chain request has no Spending source"
        )
        XCTAssertEqual(
            SendConfirmationView.fundingSources(hasLightningInvoice: true, hasOnchainInvoice: true, offersSparkLeg: true, hardwareWalletIds: []),
            [.spending, .savings]
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

    func testSparkScreenWithdrawalsLeaveOutAPendingContactPayment() {
        snapshotAppDefaultsDomain()
        SparkManager.contactWithdrawalTxIds = []
        var toContact = Self.withdrawal(id: "contact", to: onchain.value, amountSats: 20000, timestamp: 1)
        toContact.status = .pending
        let toSavings = Self.withdrawal(id: "savings", to: "bcrt1qsavings", amountSats: 5000, timestamp: 1)
        var journal = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1)
        SparkManager.pendingContactWithdrawal = journal

        XCTAssertEqual(
            SparkManager.withdrawals([toContact, toSavings]).map(\.txid),
            ["tx-savings"],
            "Before Spark returns it, the open journal's address and amount tell the contact payment apart"
        )
        journal.paymentId = "contact"
        SparkManager.pendingContactWithdrawal = journal
        XCTAssertEqual(
            SparkManager.withdrawals([toContact, toSavings]).map(\.txid),
            ["tx-savings"],
            "A contact payment Spark keeps pending is not a transfer to savings"
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
