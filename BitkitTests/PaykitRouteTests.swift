@testable import Bitkit
import BitkitCore
import BreezSdkSpark
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

    func testLegPreparesTheRequestBeforeItsProofIsStarted() async throws {
        var steps: [String] = []
        let identity = try await PaykitRouteService.startLegRequestProof(
            prepareProof: { steps.append("proof") },
            prepareRequest: { steps.append("request") },
            paymentIdentity: { steps.append("identity"); return "payer" },
            markStarted: { steps.append("started \($0)") },
            cancelProof: { steps.append("cancel") },
            releasePaymentList: { steps.append("release") }
        )

        XCTAssertEqual(identity, "payer")
        XCTAssertEqual(steps, ["proof", "request", "identity", "started payer"], "The request is approved before Spark's payment check")
    }

    func testLegThatFailsBeforeSendingFreesTheRequest() async {
        struct Refused: Error {}
        for failing in ["proof", "request", "started"] {
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
                    markStarted: {
                        _ in if failing == "started" {
                            throw Refused()
                        }
                    },
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
