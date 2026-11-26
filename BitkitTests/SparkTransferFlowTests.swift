@testable import Bitkit
import LDKNode
import XCTest

final class SparkTransferFlowTests: XCTestCase {
    private let ceiling: UInt64 = 1000

    private var store = SparkSentDeposits()

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try SparkSentDeposits(defaults: makeIsolatedDefaults())
    }

    private func choice(earlyFee: UInt64) -> SparkClaimOffer.Kind {
        .choice(earlyFeeSats: earlyFee, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3)
    }

    func testInstantWithinCeilingClaimsEarly() {
        XCTAssertEqual(SparkClaimDecision.onOffer(choice(earlyFee: 900), speed: .instant, ceilingSats: ceiling), .claiming)
        XCTAssertEqual(SparkClaimDecision.onOffer(choice(earlyFee: ceiling), speed: .instant, ceilingSats: ceiling), .claiming)
    }

    func testInstantOverCeilingAsksBeforePaying() {
        XCTAssertEqual(
            SparkClaimDecision.onOffer(choice(earlyFee: 1500), speed: .instant, ceilingSats: ceiling),
            .repriced(feeSats: 1500)
        )
    }

    func testInstantWithoutEarlyOfferWaitsForConfirmations() {
        XCTAssertEqual(
            SparkClaimDecision.onOffer(.standard(feeSats: 198, confirmations: 3), speed: .instant, ceilingSats: ceiling),
            .unavailable
        )
    }

    func testInstantClaimedBySdkShowsAddingUntilSparkListsItClaimed() {
        XCTAssertEqual(
            SparkClaimDecision.onOffer(.automatic(feeSats: 300, confirmations: 0), speed: .instant, ceilingSats: ceiling),
            .adding,
            "Success showed before Spark claimed the deposit"
        )
    }

    func testLaterNeverClaimsEarly() {
        XCTAssertEqual(SparkClaimDecision.onOffer(choice(earlyFee: 10), speed: .later, ceilingSats: ceiling), .later)
        XCTAssertEqual(
            SparkClaimDecision.onOffer(.standard(feeSats: 198, confirmations: 3), speed: .later, ceilingSats: ceiling),
            .later
        )
    }

    func testClaimOutcomes() {
        XCTAssertEqual(SparkClaimDecision.onClaim(.claimed), .added)
        XCTAssertEqual(SparkClaimDecision.onClaim(.submitted), .adding)
        XCTAssertEqual(SparkClaimDecision.onClaim(.repriced(requiredFeeSats: 1200)), .repriced(feeSats: 1200))
        XCTAssertEqual(SparkClaimDecision.onClaim(.declined), .unavailable)
        XCTAssertNil(SparkClaimDecision.onClaim(.waiting))
    }

    @MainActor
    func testLaterBroadcastSkipsTheClaim() {
        let flow = SparkTransferFlow(amountSats: 100_000, speed: .later, quote: quote, sentDeposits: store)
        flow.onBroadcast(txid: "txid")
        XCTAssertEqual(flow.claimState, .later)
    }

    @MainActor
    func testWaitFallsBackToLater() {
        let flow = SparkTransferFlow(amountSats: 100_000, claimState: .repriced(feeSats: 1500), sentDeposits: store)
        flow.waitForConfirmations()
        XCTAssertEqual(flow.claimState, .later)
        XCTAssertTrue(flow.hasWaited)
    }

    @MainActor
    func testWaitAfterAClaimTimeRepriceClearsTheEarlyClaimCap() async throws {
        var released: [String] = []
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { _, _ in .repriced(requiredFeeSats: 1500) },
            isUnclaimed: { _ in true },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { released.append($0.txid)
                return true
            }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2, sentDeposits: store)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.waitForConfirmations()
        for _ in 0 ..< 100 where released.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(flow.claimState, .later)
        XCTAssertEqual(released, ["txid"], "Spark may still claim early at the cap Wait declined")
    }

    @MainActor
    func testWaitClearsTheEarlyClaimCapAgainWhenAnotherClaimHeldTheDeposit() async throws {
        var releaseCalls = 0
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { _, _ in .repriced(requiredFeeSats: 1500) },
            isUnclaimed: { _ in true },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { _ in
                releaseCalls += 1
                // The first call meets Spark's own sync claiming the deposit, which leaves the cap in place.
                return releaseCalls > 1
            }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2, sentDeposits: store)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()

        flow.waitForConfirmations()
        for _ in 0 ..< 100 where releaseCalls < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(releaseCalls, 2, "Wait gave up on the early claim cap after Spark was busy with the deposit")
    }

    @MainActor
    func testWaitBeforeAnyClaimAttemptLeavesTheDepositAlone() async throws {
        var released: [String] = []
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 1500, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { _, _ in .claimed },
            isUnclaimed: { _ in true },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { released.append($0.txid)
                return true
            }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2, sentDeposits: store)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.waitForConfirmations()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(released, [])
    }

    @MainActor
    func testARelaunchShowsTheChangedFeeAgain() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 1500)])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        let relaunched = SparkTransferFlow(sentDeposits: store)
        relaunched.showDeposit(txid: "txid")

        XCTAssertEqual(relaunched.claimState, .repriced(feeSats: 1500), "A relaunch dropped Wait and Approve")
    }

    @MainActor
    func testARelaunchKeepsTheChoiceMadeOverAChangedFee() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 1500)])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        flow.waitForConfirmations()

        let relaunched = SparkTransferFlow(sentDeposits: store)
        relaunched.showDeposit(txid: "txid")

        XCTAssertEqual(relaunched.claimState, .later)
        XCTAssertTrue(relaunched.hasWaited)
    }

    @MainActor
    func testARelaunchResumesTheInstantClaimAtTheApprovedCeiling() async {
        store.update(txid: "txid") {
            $0.amountSats = 100_000
            $0.ceilingSats = 1093
            $0.state = .looking
        }
        let calls = PollCalls()
        let relaunched = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.submitted], calls: calls)

        relaunched.resumeSentDeposits()
        relaunched.showDeposit(txid: "txid")
        await relaunched.waitForClaim()

        XCTAssertEqual(calls.ceilings, [1093], "The relaunch dropped the early claim")
        XCTAssertEqual(relaunched.claimState, .adding)
    }

    @MainActor
    func testWaitOnAChangedFeeAfterARelaunchClearsTheEarlyClaimCap() async throws {
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.repriced(requiredFeeSats: 1500)])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        let calls = PollCalls()
        let relaunched = pollingFlow(offers: [], calls: calls)

        relaunched.showDeposit(txid: "txid")
        XCTAssertEqual(relaunched.claimState, .repriced(feeSats: 1500))
        relaunched.waitForConfirmations()
        for _ in 0 ..< 100 where calls.released.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(calls.released, ["txid"], "Spark may still claim early at the cap Wait declined")
        XCTAssertNil(store.load()["txid"]?.claimedOffer)
    }

    @MainActor
    func testARelaunchLeavesADepositSparkClaimedMeanwhile() async {
        store.update(txid: "txid") {
            $0.ceilingSats = 1093
            $0.state = .looking
        }
        let calls = PollCalls()
        let relaunched = pollingFlow(offers: [choice(earlyFee: 900)], calls: calls)

        store.remove(txids: ["TXID"])
        relaunched.resumeSentDeposits()
        relaunched.showDeposit(txid: "txid")
        await relaunched.waitForClaim()

        XCTAssertEqual(calls.offers, 0, "A claimed deposit was followed again")
        XCTAssertTrue(store.load().isEmpty)
    }

    @MainActor
    func testARelaunchBeforeTheClaimWasSavedDoesNotStartAnInstantClaim() async {
        store.record(txid: "txid", amountSats: 100_000)
        let calls = PollCalls()
        let relaunched = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.submitted], calls: calls)

        relaunched.resumeSentDeposits()
        relaunched.showDeposit(txid: "txid")
        await relaunched.waitForClaim()

        XCTAssertEqual(calls.offers, 0, "A transfer whose speed was never saved was claimed early at no approved ceiling")
    }

    @MainActor
    func testADepositWhoseFundingAFeeBumpReplacedLeavesTheBanner() async {
        store.record(txid: "replaced", amountSats: 100_000)
        store.record(txid: "pending", amountSats: 50000, walletId: "jade:wallet")
        store.record(txid: "listed", amountSats: 70000)
        var walletIds: [String: String] = [:]

        let replaced = await SparkManager.replacedSentDeposits(store.load(), listed: ["listed"]) { txid, walletId in
            walletIds[txid] = walletId
            return txid == "pending"
        }

        XCTAssertEqual(replaced, ["replaced"])
        XCTAssertEqual(walletIds, ["replaced": WalletScope.default, "pending": "jade:wallet"])
    }

    func testADepositSparkNeverListedIsDroppedAfterTwoWeeks() {
        store.update(txid: "txid") { $0.sentAt = Date(timeIntervalSinceNow: -15 * 24 * 60 * 60) }

        XCTAssertTrue(store.load().isEmpty)
    }

    @MainActor
    func testAClaimedDepositIsNoLongerKeptForARelaunch() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.claimed])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .added)
        XCTAssertTrue(store.load().isEmpty)
    }

    @MainActor
    func testTimeoutWhenSparkNeverListsTheDeposit() async {
        let flow = pollingFlow(offers: [nil, nil, nil])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .notSeen)
    }

    @MainActor
    func testListedDepositWhoseEarlyClaimKeepsWaitingIsNotUnseen() async {
        let calls = PollCalls()
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.waiting], pollAttempts: 3, calls: calls)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .unavailable)
        XCTAssertEqual(calls.offers, 1, "A waiting claim asked the provider for a quote again")
        XCTAssertEqual(calls.claims, 1)
        XCTAssertEqual(calls.unclaimedChecks, 2)
    }

    @MainActor
    func testAWaitingEarlyClaimThePollGivesUpOnClearsItsFeeCap() async throws {
        let calls = PollCalls()
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.waiting], pollAttempts: 3, calls: calls)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        for _ in 0 ..< 100 where calls.released.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(flow.claimState, .unavailable)
        XCTAssertEqual(calls.released, ["txid"], "Spark may still claim early while the transfer shows the normal speed")
    }

    @MainActor
    func testAWaitingEarlyClaimIsCappedAtTheApprovedFeeNotTheFirstQuote() async {
        let calls = PollCalls()
        let flow = pollingFlow(offers: [choice(earlyFee: 300)], claims: [.waiting], pollAttempts: 2, calls: calls)
        flow.onBroadcast(txid: "txid", ceilingSats: 500)
        await flow.waitForClaim()
        XCTAssertEqual(calls.ceilings, [500], "Spark would leave a later offer under the approved fee unclaimed")
    }

    @MainActor
    func testDepositListedThenGoneWasAdded() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.waiting], unclaimed: [false])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
    }

    @MainActor
    func testWaitingWatchesTheDepositUntilSparkClaimsIt() async {
        let calls = PollCalls()
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.waiting], unclaimed: [true, false], pollAttempts: 5, calls: calls)
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
        XCTAssertEqual(calls.offers, 1)
        XCTAssertEqual(calls.claims, 1)
        XCTAssertEqual(calls.unclaimedChecks, 2)
    }

    @MainActor
    func testPayAfterRepriceClaimsAtTheNewFee() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 1500), choice(earlyFee: 1500)], claims: [.claimed])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.payRepriced()
        XCTAssertEqual(flow.claimState, .claiming)
        XCTAssertTrue(flow.isFeeApproved)
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
    }

    @MainActor
    func testDeclinedEarlyClaimWaitsForConfirmations() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 900)], claims: [.declined])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .unavailable)
    }

    @MainActor
    func testANewTransferKeepsTheEarlierClaimAndItsResultOffScreen() async throws {
        var claimed: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let operations = SparkClaimOperations(
            offer: { txid in SparkClaimOffer(txid: txid, vout: 0, kind: .choice(
                earlyFeeSats: 900, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3
            )) },
            claimEarly: { offer, _ in
                await withCheckedContinuation { release = $0 }
                claimed.append(offer.txid)
                return .claimed
            },
            isUnclaimed: { _ in true },
            refresh: {},
            sleep: { _ in }
        )
        let flow = SparkTransferFlow(amountSats: 100_000, quote: quote, operations: operations, pollAttempts: 2, sentDeposits: store)
        flow.onBroadcast(txid: "first")
        for _ in 0 ..< 100 where release == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        flow.beginIfBroadcast()
        flow.speed = .later
        flow.onBroadcast(txid: "second")
        release?.resume()
        for _ in 0 ..< 100 where claimed.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(claimed, ["first"], "The earlier deposit's early claim went on")
        XCTAssertEqual(flow.claimState, .later, "Its result stays off the new transfer's screen")
    }

    @MainActor
    func testSubmittedEarlyClaimShowsAddingUntilTheDepositSettles() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.submitted])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .adding)
        XCTAssertFalse(flow.claimState.isDone, "Setting up showed success while the claim was only submitted")

        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: false)])
        XCTAssertEqual(flow.claimState, .adding)
        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .added)
        XCTAssertTrue(flow.claimState.isDone)
    }

    @MainActor
    func testTheDepositStaysSeenWhileSparkDropsItFromItsListToClaimIt() {
        let flow = SparkTransferFlow(amountSats: 100_000, speed: .later, quote: quote, sentDeposits: store)
        flow.onBroadcast(txid: "TXID")
        let broadcast = [SparkDeposit(txid: "TXID", amountSats: 100_000, isClaimed: false, isListed: false)]
        XCTAssertFalse(flow.isDepositSeen(in: broadcast))

        let listed = [SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: false)]
        XCTAssertTrue(flow.isDepositSeen(in: listed))
        flow.noteSettled(listed)
        XCTAssertTrue(flow.isDepositSeen(in: broadcast), "Setting up went back to Processing Payment while Spark claimed it")
    }

    @MainActor
    func testALaterTransferEndsOnceSparkClaimsItsDeposit() {
        let flow = SparkTransferFlow(amountSats: 100_000, speed: .later, quote: quote, sentDeposits: store)
        flow.onBroadcast(txid: "txid")

        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: false)])
        XCTAssertEqual(flow.claimState, .later)
        flow.noteSettled([SparkDeposit(txid: "other", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .later)
        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .added, "Later stayed in progress after the deposit reached spending")
    }

    @MainActor
    func testTheTransferBannerOpensTheFollowedDepositAtItsStep() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.submitted])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()

        flow.showDeposit(txid: "TXID")

        XCTAssertEqual(flow.claimState, .adding, "The banner lost the followed transfer's step")
    }

    @MainActor
    func testTheTransferBannerReopensARepricedDepositAfterAnotherTransferBegan() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 1500), choice(earlyFee: 1500)], claims: [.claimed])
        flow.onBroadcast(txid: "txid")
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))

        flow.beginIfBroadcast()
        flow.showDeposit(txid: "txid")

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500), "The banner lost the pending fee decision")
        flow.payRepriced()
        await flow.waitForClaim()
        XCTAssertEqual(flow.claimState, .added)
    }

    @MainActor
    func testTheTransferBannerReopensAWaitedDepositAtTheNormalSpeedOnTheLastStep() {
        let flow = SparkTransferFlow(amountSats: 100_000, speed: .later, quote: quote, sentDeposits: store)
        flow.onBroadcast(txid: "txid")
        flow.claimState = .repriced(feeSats: 1500)
        flow.waitForConfirmations()

        flow.showDeposit(txid: "TXID")

        let stage = SettingUpStage(
            state: flow.claimState, isSeen: true, approvedFee: flow.isFeeApproved, hasWaited: flow.hasWaited
        )
        XCTAssertEqual(stage, .adding(normalSpeed: true), "The banner lost the Wait over the changed fee")
    }

    @MainActor
    func testTheTransferBannerOpensADepositNoClaimFollowsAsAddedAtMaturity() {
        let flow = SparkTransferFlow(sentDeposits: store)

        flow.showDeposit(txid: "txid")
        XCTAssertEqual(flow.claimState, .later)
        XCTAssertEqual(SettingUpStage(state: flow.claimState), .processing(normalSpeed: true))

        flow.noteSettled([SparkDeposit(txid: "txid", amountSats: 100_000, isClaimed: true)])
        XCTAssertEqual(flow.claimState, .added, "The opened deposit stayed in progress after Spark claimed it")
    }

    func testTheTransferBannerPicksTheFirstUnclaimedDeposit() {
        let deposits = [
            SparkDeposit(txid: "claimed", amountSats: 1, isClaimed: true),
            SparkDeposit(txid: "pending", amountSats: 1, isClaimed: false),
        ]
        XCTAssertEqual(deposits.inProgressTxid, "pending")
        XCTAssertNil([SparkDeposit(txid: "claimed", amountSats: 1, isClaimed: true)].inProgressTxid)
    }

    @MainActor
    func testARecoveredFundingClaimsEarlyOnlyUpToTheSwipedCeiling() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        flow.quote = quote(instantMax: 337)
        let attemptId = UUID()
        flow.approveSwipe()
        flow.bindApproval(to: attemptId)
        // The confirm screen requoted under the pending sheet while fee rates rose.
        flow.quote = quote(instantMax: 3010)

        flow.onRecoveredBroadcast(txid: "txid", attemptId: attemptId)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "Paid an early claim fee the user never approved")
    }

    @MainActor
    func testASwipeApprovesNoHigherCeilingThanTheQuoteItShowed() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        // The requote before sending raised the ceiling over the one the swiped quote showed.
        flow.quote = quote(instantMax: 3010)
        let ceilingSats = flow.approveSwipe(shownCeilingSats: 337)
        XCTAssertEqual(ceilingSats, 337)

        flow.onBroadcast(txid: "txid", ceilingSats: ceilingSats)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "Claimed early at a ceiling the swipe never showed")
    }

    @MainActor
    func testARecoveredFundingKeepsItsOwnApprovalWhenALaterSwipeIsRejected() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let first = UUID()
        flow.quote = quote(instantMax: 337)
        flow.approveSwipe()
        flow.bindApproval(to: first)
        // A second swipe at a higher ceiling is rejected while the first funding is still unresolved, so the attempt
        // the screen sees is still the first one.
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: first)

        flow.onRecoveredBroadcast(txid: "txid", attemptId: first)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "The first funding claimed early at the rejected swipe's ceiling")
    }

    @MainActor
    func testASwipeRefusedForAnOlderFundingAfterARelaunchLeavesItsEarlyClaimAsking() async {
        // After a relaunch nothing is tied to the older funding still unresolved, which refuses the new swipe.
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let older = UUID()
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: older, after: OnchainSendAttemptError.blocked(nil))

        flow.onRecoveredBroadcast(txid: "txid", attemptId: older)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "The older funding claimed early at the refused swipe's ceiling")
    }

    @MainActor
    func testASwipeWhoseFundingIsLeftUnresolvedTiesItsApprovalToIt() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let attemptId = UUID()
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: attemptId, after: OnchainSendAttemptError.unresolved)

        flow.onRecoveredBroadcast(txid: "txid", attemptId: attemptId)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .added, "The funding this swipe left unresolved lost the approval it gave")
    }

    @MainActor
    func testAFundingThatResolvesOffTheConfirmScreenIsFollowedOnce() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let attemptId = UUID()
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: attemptId, after: OnchainSendAttemptError.unresolved)

        // The swipe's funding resolves while the Amount screen shows, so no confirm screen follows it.
        XCTAssertTrue(flow.followIfOwned(txid: "txid", attemptId: attemptId), "A funding this flow approved went unfollowed")
        await flow.waitForClaim()

        XCTAssertEqual(flow.txid, "txid")
        XCTAssertEqual(flow.claimState, .added)
        XCTAssertFalse(flow.followIfOwned(txid: "txid", attemptId: attemptId), "A followed funding was followed again")
    }

    @MainActor
    func testANewAmountAfterAFollowedFundingIsANewTransfer() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        let attemptId = UUID()
        flow.start(amountSats: 40000, isMaxAmount: false)
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()
        flow.bindApproval(to: attemptId, after: OnchainSendAttemptError.unresolved)
        XCTAssertTrue(flow.followIfOwned(txid: "txid", attemptId: attemptId))
        await flow.waitForClaim()

        flow.start(amountSats: 40000, isMaxAmount: false)
        XCTAssertEqual(flow.txid, "txid", "the transfer lost the funding it follows")
        // The funding resolved while Spending Amount showed, and a new amount is a new transfer.
        flow.start(amountSats: 50000, isMaxAmount: false)
        XCTAssertNil(flow.txid, "an earlier funding stood in for a new transfer's swipe")
    }

    @MainActor
    func testAFundingWhoseOutcomeIsUnknownIsKeptNotFailed() {
        XCTAssertEqual(try TransferViewModel.fundedTxid(.accepted(txid: "txid")), "txid")
        XCTAssertThrowsError(try TransferViewModel.fundedTxid(.unknown(txid: "txid"))) { error in
            XCTAssertEqual((error as? SparkFundingUnresolved)?.txid, "txid", "A funding that may be on the network read as failed")
        }
        XCTAssertThrowsError(try TransferViewModel.fundedTxid(.rejected(txid: "txid", reason: "fee too low"))) { error in
            XCTAssertEqual((error as? SparkFundingUnresolved)?.rejectionReason, "fee too low")
        }
    }

    @MainActor
    func testARecoveredFundingWithNoApprovalAsksBeforeAnEarlyClaim() async {
        let flow = pollingFlow(offers: [choice(earlyFee: 800)], claims: [.claimed])
        flow.quote = quote(instantMax: 3010)
        flow.approveSwipe()

        flow.onRecoveredBroadcast(txid: "txid", attemptId: UUID())
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 800), "Claimed early on an approval made for another attempt")
    }

    private func quote(instantMax: UInt64) -> SparkTransferQuote {
        SparkTransferQuote(
            address: "bcrt1qtest", satsPerVbyte: 6, networkFeeSats: 577, depositSats: 100_000,
            claimFees: SparkClaimFees(instantMaxSats: instantMax, laterSats: 198)
        )
    }

    private final class PollCalls {
        var offers = 0
        var claims = 0
        var unclaimedChecks = 0
        var ceilings: [UInt64] = []
        var released: [String] = []
    }

    /// A flow whose poll answers with `offers` in turn (nil once they run out), whose claims answer with `claims`, and
    /// whose unclaimed checks answer with `unclaimed` (still unclaimed once they run out).
    @MainActor
    private func pollingFlow(
        offers: [SparkClaimOffer.Kind?],
        claims: [SparkEarlyClaim] = [],
        unclaimed: [Bool] = [],
        pollAttempts: Int? = nil,
        calls: PollCalls = PollCalls()
    ) -> SparkTransferFlow {
        var offers = offers
        var claims = claims
        var unclaimed = unclaimed
        let operations = SparkClaimOperations(
            offer: { txid in
                calls.offers += 1
                guard !offers.isEmpty, let kind = offers.removeFirst() else { return nil }
                return SparkClaimOffer(txid: txid, vout: 0, kind: kind)
            },
            claimEarly: { _, ceilingSats in
                calls.claims += 1
                calls.ceilings.append(ceilingSats)
                return claims.isEmpty ? .waiting : claims.removeFirst()
            },
            isUnclaimed: { _ in
                calls.unclaimedChecks += 1
                return unclaimed.isEmpty ? true : unclaimed.removeFirst()
            },
            refresh: {},
            sleep: { _ in },
            releaseEarlyClaim: { offer in
                calls.released.append(offer.txid)
                return true
            }
        )
        return SparkTransferFlow(
            amountSats: 100_000,
            quote: quote,
            operations: operations,
            pollAttempts: pollAttempts ?? offers.count + 1,
            sentDeposits: store
        )
    }

    @MainActor
    func testARefusedFixedFundingKeepsItsFeeUntilTheTransferChanges() {
        let flow = SparkTransferFlow(sentDeposits: store)
        flow.start(amountSats: 50000, isMaxAmount: false)
        flow.onFundingChanged(preparedFeeSats: 700)
        XCTAssertEqual(flow.fixedFeeFloorSats, 700, "The next swipe would approve less than the refused fee")
        flow.start(amountSats: 50000, isMaxAmount: false)
        XCTAssertEqual(flow.fixedFeeFloorSats, 700)
        flow.start(amountSats: 60000, isMaxAmount: false)
        XCTAssertNil(flow.fixedFeeFloorSats)

        flow.start(amountSats: 60000, isMaxAmount: true)
        flow.onFundingChanged(preparedFeeSats: 700)
        XCTAssertNil(flow.fixedFeeFloorSats, "Max re-prices from the balance instead")
    }

    func testQuoteTiles() {
        XCTAssertEqual(quote.toSpendingSats(for: .instant), 100_000 - 1093)
        XCTAssertEqual(quote.toSpendingSats(for: .later), 100_000 - 198)
        XCTAssertEqual(quote.totalSats, 100_577)
    }

    func testMatureClaimFee() {
        XCTAssertEqual(SparkManager.matureDepositClaimFeeSats(halfHourFeeRate: 2), 198)
    }

    private var quote: SparkTransferQuote {
        SparkTransferQuote(
            address: "bcrt1qtest",
            satsPerVbyte: 6,
            networkFeeSats: 577,
            depositSats: 100_000,
            claimFees: SparkClaimFees(instantMaxSats: 1093, laterSats: 198)
        )
    }

    func testFeeGridTapStaysInBitcoinWithoutARate() {
        XCTAssertFalse(SpendingConfirmFees.togglesDisplay(from: .bitcoin, hasRate: false))
        XCTAssertTrue(SpendingConfirmFees.togglesDisplay(from: .bitcoin, hasRate: true))
        XCTAssertTrue(SpendingConfirmFees.togglesDisplay(from: .fiat, hasRate: false))
    }

    func testFiatConversionRejectsUnusableRates() {
        XCTAssertNil(CurrencyViewModel.sats(fiatAmount: 10, rate: 0))
        XCTAssertNil(CurrencyViewModel.sats(fiatAmount: 10, rate: -1))
        XCTAssertNil(CurrencyViewModel.sats(fiatAmount: -10, rate: 100_000))
        XCTAssertNil(CurrencyViewModel.sats(fiatAmount: .greatestFiniteMagnitude, rate: 1))
        XCTAssertEqual(CurrencyViewModel.sats(fiatAmount: 50, rate: 100_000), 50000)
    }

    func testPrimaryAmountsStayInBitcoinWithoutAUsableRate() {
        XCTAssertEqual(MoneyText.primaryUnit(.fiat, hasUsableRate: false), .bitcoin)
        XCTAssertEqual(MoneyText.primaryUnit(.fiat, hasUsableRate: true), .fiat)
        XCTAssertEqual(MoneyText.primaryUnit(.bitcoin, hasUsableRate: false), .bitcoin)
        // The paired line shows the other unit, never bitcoin twice.
        XCTAssertEqual(MoneyText.secondaryUnit(.fiat, hasUsableRate: false), .fiat)
        XCTAssertEqual(MoneyText.secondaryUnit(.fiat, hasUsableRate: true), .bitcoin)
        XCTAssertEqual(MoneyText.secondaryUnit(.bitcoin, hasUsableRate: false), .fiat)
    }
}
