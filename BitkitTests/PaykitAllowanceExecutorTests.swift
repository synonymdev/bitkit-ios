@testable import Bitkit
import Combine
import Foundation
import Paykit
import XCTest

final class PaykitAllowanceExecutorTests: XCTestCase {
    private typealias Fixtures = PaykitAllowanceFixtures

    private static let admissionCalls = [
        "evaluateAllowanceCandidates",
        "claimForExecution",
        "recordAcceptanceIntent",
        "acceptPaymentRequestAutomatically",
        "reserveAutomaticPayment",
        "receivePrivateMessages",
        "beginPaymentExecution",
        "consumePaymentList",
        "ensurePaymentAllowed",
        "prepareProof",
        "associateLightningPayment",
        "payLightning",
        "resolvePaymentList",
    ]

    // MARK: Admission

    func testUncoveredRequestNeverReachesTheSdk() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let uncovering: [[PaykitAllowance]] = [
            [],
            [Fixtures.allowance(role: .allowee)],
            [Fixtures.allowance(state: .proposed)],
            [Fixtures.allowance(state: .ended)],
            [Fixtures.allowance(counterparty: Fixtures.otherCounterpartyKey)],
        ]

        for allowances in uncovering {
            let result = await harness.executor.autoPay(request, allowances: allowances, identity: Fixtures.identityKey)
            XCTAssertEqual(result, .notCovered)
        }
        XCTAssertEqual(harness.log.entries, [])
    }

    func testCoveredLightningRequestRunsAdmissionInOrderAndHandsOffToTheNode() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()

        let result = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .started)
        let log = harness.log.entries
        XCTAssertEqual(log.filter(Self.admissionCalls.contains), Self.admissionCalls)
        let resolveIndex = try XCTUnwrap(log.firstIndex(of: "resolve"))
        let acceptIndex = try XCTUnwrap(log.firstIndex(of: "acceptPaymentRequestAutomatically"))
        XCTAssertLessThan(resolveIndex, acceptIndex)
        XCTAssertFalse(log.contains("recordPaymentOutcome"))

        let evaluatedTimes = await harness.sdk.evaluatedTrustedTimes
        XCTAssertEqual(evaluatedTimes, [PaykitAllowanceTime.format(Fixtures.now)])
        let selections = await harness.sdk.selections
        XCTAssertEqual(selections.map(\.allowanceId), [Fixtures.walletAllowanceId])
        let acceptedEndpoints = await harness.sdk.acceptedEndpointIdentifiers
        XCTAssertEqual(acceptedEndpoints, [Fixtures.lightningIdentifier])
        let reservedRevisions = await harness.sdk.reservedAssociationRevisions
        XCTAssertEqual(reservedRevisions, [1])
        let preparedProofs = await harness.payer.preparedProofs
        XCTAssertEqual(
            preparedProofs,
            [.init(appId: AllowanceHarness.paymentAppId, endpoint: Fixtures.lightningIdentifier, allowanceId: Fixtures.walletAllowanceId)]
        )
        let claimed = await harness.payer.claimedRequestIds
        XCTAssertEqual(claimed, [request.id])
        let intents = await harness.payer.acceptanceIntents
        XCTAssertEqual(intents, [request.id], "The request stays this device's own once accepted, so a failed payment comes back as manual")
        XCTAssertFalse(harness.log.entries.contains("discardAcceptanceIntent"))
        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.uncertain], "A hand-off to the node keeps the payment list consumed")
        let associatedHashes = await harness.payer.associatedPaymentHashes
        XCTAssertEqual(associatedHashes, [AllowanceHarness.paymentHash])
        let payments = await harness.payer.lightningPayments
        XCTAssertEqual(payments, [.init(bolt11: AllowanceHarness.invoice, sats: nil)])

        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.count, 1)
        let entry = try XCTUnwrap(journal.first)
        XCTAssertEqual(entry.attemptId, AllowanceSdkMock.automaticAttemptId)
        XCTAssertEqual(entry.stage, .sent)
        XCTAssertTrue(entry.isAutomatic)
        XCTAssertEqual(entry.requestId, request.id)
        XCTAssertEqual(entry.allowanceId, Fixtures.walletAllowanceId)
        XCTAssertEqual(entry.amountSats, 1000)
        XCTAssertEqual(entry.paymentHash, AllowanceHarness.paymentHash)
        XCTAssertEqual(entry.paymentEndpointIdentifier, Fixtures.lightningIdentifier)
        let isHandling = await harness.executor.isHandling(request.id)
        XCTAssertFalse(isHandling)
    }

    func testRequestWaitsWithoutAcceptanceWhileThePayeesPaymentListIsPending() async throws {
        let harness = AllowanceHarness()
        await harness.payer.setResolveError(PaykitAllowanceError.paymentListPending)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .deferred)
        let log = harness.log.entries
        XCTAssertTrue(log.contains("resolve"))
        XCTAssertFalse(log.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(log.contains("markPaymentManualOnly"))
    }

    @MainActor
    func testManagerKeepsCoveredRequestsOffTheSendSheetUntilLightningIsReady() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms())])
        var ready = false
        let manager = PaykitAllowanceManager(
            sdk: harness.sdk,
            executor: harness.executor,
            now: { PaykitAllowanceFixtures.now },
            canPayNow: { ready }
        )
        await manager.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest()

        let handledWhileReconnecting = await manager.processIncomingRequests([request])

        XCTAssertFalse(handledWhileReconnecting)
        XCTAssertFalse(harness.log.entries.contains("evaluateAllowanceCandidates"))
        let waiting = await manager.isAutomaticallyHandling(request)
        XCTAssertTrue(waiting)

        ready = true
        let handled = await manager.processIncomingRequests([request])

        XCTAssertTrue(handled)
        XCTAssertTrue(harness.log.entries.contains("payLightning"))
    }

    @MainActor
    func testManagerOwnsACoveredRequestBeforeTheFirstPassAndReleasesItOnceFoundManual() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms())])
        await harness.sdk.setCandidates([AllowanceHarness.candidate(blocked: .sharedRule(code: "amount_outside_range"))])
        let manager = PaykitAllowanceManager(
            sdk: harness.sdk,
            executor: harness.executor,
            now: { PaykitAllowanceFixtures.now },
            canPayNow: { true }
        )
        await manager.activate(identity: Fixtures.identityKey)
        let covered = try Fixtures.paymentRequest()
        let uncovered = try Fixtures.paymentRequest(id: "550e8400-e29b-41d4-a716-446655440002", counterparty: Fixtures.otherCounterpartyKey)

        let ownsBeforeAnyPass = await manager.isAutomaticallyHandling(covered)
        let ownsUncovered = await manager.isAutomaticallyHandling(uncovered)

        XCTAssertTrue(ownsBeforeAnyPass, "No sheet may open between the request arriving and the first pass over it")
        XCTAssertFalse(ownsUncovered)

        _ = await manager.processIncomingRequests([covered, uncovered])

        let ownsAfterManual = await manager.isAutomaticallyHandling(covered)
        XCTAssertFalse(ownsAfterManual, "A request the pass found manual goes to the Send sheet")
    }

    @MainActor
    func testManagerHandsBackARequestAboveTheLimitsWhileWaitingForAChannel() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms())])
        let manager = PaykitAllowanceManager(
            sdk: harness.sdk,
            executor: harness.executor,
            now: { PaykitAllowanceFixtures.now },
            canPayNow: { false }
        )
        await manager.activate(identity: Fixtures.identityKey)
        let aboveLimit = try Fixtures.paymentRequest(amount: "0.0001")
        let withinLimits = try Fixtures.paymentRequest(id: "550e8400-e29b-41d4-a716-446655440002")
        let events = AllowanceEventRecorder()

        let handedBack = await manager.processIncomingRequests([aboveLimit, withinLimits])

        XCTAssertTrue(handedBack)
        let ownsAboveLimit = await manager.isAutomaticallyHandling(aboveLimit)
        let ownsWithinLimits = await manager.isAutomaticallyHandling(withinLimits)
        XCTAssertFalse(ownsAboveLimit, "A request over the limits goes to the Send sheet without waiting for a channel")
        XCTAssertTrue(ownsWithinLimits, "A request within the limits waits for the channel")
        XCTAssertEqual(events.events.filter {
            if case .limitReached = $0 {
                true
            } else {
                false
            }
        }.count, 1)
        XCTAssertFalse(harness.log.entries.contains("payLightning"))
    }

    @MainActor
    func testManagerMayCoverAContactItWasAskedToGrant() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(state: .proposed, terms: Fixtures.standardTerms())])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertTrue(try manager.mayCover(Fixtures.paymentRequest()))
        XCTAssertFalse(try manager.mayCover(Fixtures.paymentRequest(counterparty: Fixtures.otherCounterpartyKey)))
        XCTAssertFalse(manager.isUpdating)
    }

    @MainActor
    func testManagerMayNotCoverAContactWhoseAllowanceEnded() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(state: .ended, terms: Fixtures.standardTerms())])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertFalse(try manager.mayCover(Fixtures.paymentRequest()), "An ended allowance can't start covering a request")
    }

    @MainActor
    func testManagerKeepsADeferredRequestOffTheSendSheet() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms())])
        await harness.payer.setResolveError(PaykitAllowanceError.paymentListPending)
        let manager = PaykitAllowanceManager(
            sdk: harness.sdk,
            executor: harness.executor,
            now: { PaykitAllowanceFixtures.now },
            canPayNow: { true }
        )
        await manager.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest()

        let handled = await manager.processIncomingRequests([request])

        XCTAssertFalse(handled)
        let waiting = await manager.isAutomaticallyHandling(request)
        XCTAssertTrue(waiting)
    }

    func testBlockedCandidateStaysManualWithoutAcceptance() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setCandidates([
            AllowanceHarness.candidate(blocked: .sharedRule(code: "amount_outside_range")),
        ])

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let log = harness.log.entries
        XCTAssertTrue(log.contains("evaluateAllowanceCandidates"))
        XCTAssertFalse(log.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(log.contains("reserveAutomaticPayment"))
        XCTAssertFalse(log.contains("resolve"))
        XCTAssertFalse(log.contains("payLightning"))
    }

    func testOverMonthlyCapStaysManualAndNotifiesOnce() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setAccountingState(Self.stateNearTheMonthlyCap())
        let request = try Fixtures.paymentRequest()
        let events = AllowanceEventRecorder()

        let first = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)
        let second = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(first, .manual)
        XCTAssertEqual(second, .manual)
        let log = harness.log.entries
        XCTAssertFalse(log.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(log.contains("reserveAutomaticPayment"))
        XCTAssertFalse(log.contains("resolve"))
        let limitEvents = events.events.filter { $0 == .limitReached(counterparty: Fixtures.counterpartyKey, amountSats: 1000) }
        XCTAssertEqual(limitEvents.count, 1)
    }

    func testALedgerOlderThanOneAlreadyReadKeepsTheRequestManual() async throws {
        let harness = AllowanceHarness()
        harness.store.seed(PaykitAllowanceLocalState(ledgerRevisionFloor: 5), identity: Fixtures.identityKey)
        await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4))

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(harness.log.entries.contains("resolve"))
        let floor = await harness.executor.localState(identity: Fixtures.identityKey).ledgerRevisionFloor
        XCTAssertEqual(floor, 5)
    }

    func testALedgerThatGoesBehindThisWalletDuringAdmissionKeepsTheRequestManual() async throws {
        let harness = AllowanceHarness()
        harness.store.seed(PaykitAllowanceLocalState(ledgerRevisionFloor: 5), identity: Fixtures.identityKey)
        await harness.sdk.queueAccountingStates([Fixtures.accountingState(revision: 5), Fixtures.accountingState(revision: 3)])

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(harness.log.entries.contains("resolve"))
    }

    func testAMissingLedgerAfterOneWasReadKeepsTheRequestManual() async throws {
        let harness = AllowanceHarness()
        harness.store.seed(PaykitAllowanceLocalState(ledgerRevisionFloor: 5), identity: Fixtures.identityKey)
        await harness.sdk.setAccountingState(nil)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("reconcileAllowanceAccounting"))
        XCTAssertFalse(harness.log.entries.contains("resolve"))
    }

    func testAFloorThatCannotBeSavedKeepsTheRequestManual() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 7))
        harness.store.failSaves()

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(harness.log.entries.contains("resolve"))
    }

    func testAnAutomaticPaymentRaisesTheLedgerFloor() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 7))

        _ = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        let floor = await harness.executor.localState(identity: Fixtures.identityKey).ledgerRevisionFloor
        XCTAssertEqual(floor, 7)
    }

    func testLocalSpendingAboveTheLedgersKeepsTheRequestManual() async throws {
        let harness = AllowanceHarness()
        let spend = try PaykitAllowanceLocalState.AutomaticSpend(
            attemptId: "local-1",
            counterparty: Fixtures.counterpartyKey,
            allowanceId: Fixtures.walletAllowanceId,
            amountSats: 49500,
            admittedAt: XCTUnwrap(PaykitAllowanceTime.parse("2026-09-20T10:00:00Z"))
        )
        harness.store.seed(PaykitAllowanceLocalState(automaticSpends: [spend]), identity: Fixtures.identityKey)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(harness.log.entries.contains("resolve"))
    }

    func testAnAutomaticPaymentCountsLocallyUntilItFails() async throws {
        let harness = AllowanceHarness()
        await harness.executor.activate(identity: Fixtures.identityKey)

        _ = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)
        let spends = await harness.executor.localState(identity: Fixtures.identityKey).automaticSpends
        await harness.executor.lightningPaymentSettled(paymentHash: AllowanceHarness.paymentHash, succeeded: false)

        XCTAssertEqual(spends.map(\.attemptId), [AllowanceSdkMock.automaticAttemptId])
        XCTAssertEqual(spends.map(\.amountSats), [1000])
        let remaining = await harness.executor.localState(identity: Fixtures.identityKey).automaticSpends
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRecoveryDropsTheSpendOfAFailedAttemptTheJournalNoLongerHolds() async throws {
        let harness = AllowanceHarness()
        let spend = PaykitAllowanceLocalState.AutomaticSpend(
            attemptId: "trimmed-1",
            counterparty: Fixtures.counterpartyKey,
            allowanceId: Fixtures.walletAllowanceId,
            amountSats: 1000,
            admittedAt: Fixtures.now
        )
        harness.store.seed(PaykitAllowanceLocalState(automaticSpends: [spend]), identity: Fixtures.identityKey)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(occurrences: [
            Fixtures.occurrence(requestId: "trimmed-1", attempts: [Fixtures.attemptRecord(id: "trimmed-1", status: .failed)]),
        ]))

        await harness.executor.recover(identity: Fixtures.identityKey)

        let spends = await harness.executor.localState(identity: Fixtures.identityKey).automaticSpends
        XCTAssertTrue(spends.isEmpty)
    }

    func testAnAllowanceSeenEndedNeverPaysAutomaticallyAgain() async throws {
        let harness = AllowanceHarness()
        await harness.executor.rememberEndedAllowances(identity: Fixtures.identityKey, allowances: [Fixtures.allowance(state: .ended)])

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(harness.log.entries.contains("resolve"))
    }

    func testRequestAbovePerPaymentLimitNotifiesOnceWhenTheSdkBlocksIt() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setCandidates([AllowanceHarness.candidate(blocked: .sharedRule(code: "per_payment_amount_exceeded"))])
        let request = try Fixtures.paymentRequest()
        let allowance = Fixtures.allowance(perPaymentMaxSats: 500)
        let events = AllowanceEventRecorder()

        let first = await harness.executor.autoPay(request, allowances: [allowance], identity: Fixtures.identityKey)
        let second = await harness.executor.autoPay(request, allowances: [allowance], identity: Fixtures.identityKey)

        XCTAssertEqual(first, .manual)
        XCTAssertEqual(second, .manual)
        let limitEvents = events.events.filter { $0 == .limitReached(counterparty: Fixtures.counterpartyKey, amountSats: 1000) }
        XCTAssertEqual(limitEvents.count, 1)
    }

    func testAnUnsavedSpendStopsTheAttemptBeforeAnythingIsConsumed() async throws {
        let harness = AllowanceHarness()
        harness.store.seed(PaykitAllowanceLocalState(ledgerRevisionFloor: 1), identity: Fixtures.identityKey)
        harness.store.failSaves()

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("beginPaymentExecution"))
        XCTAssertFalse(harness.log.entries.contains("consumePaymentList"))
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: AllowanceSdkMock.automaticAttemptId, outcome: .failed)])
    }

    func testPaymentIsNotSentWhenTheSendingStageCannotBeSaved() async throws {
        let harness = AllowanceHarness()
        harness.store.failSavesOnceSpent()
        let request = try Fixtures.paymentRequest()

        let result = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("payLightning"))
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: AllowanceSdkMock.automaticAttemptId, outcome: .failed)])
        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.definitePreBroadcastFailure])
    }

    func testReservationBlockedForAReasonOtherThanALimitRaisesNoLimitReached() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setAutomaticReservation(.blocked(reason: .manualOnly))
        let events = AllowanceEventRecorder()

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(events.events.contains {
            if case .limitReached = $0 {
                true
            } else {
                false
            }
        })
    }

    func testBlockedReservationMarksThePaymentManualOnly() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setAutomaticReservation(.blocked(reason: .sharedRule(code: "period_amount_limit")))
        let request = try Fixtures.paymentRequest()

        let result = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let manualOnly = await harness.sdk.manualOnlyOccurrences
        XCTAssertEqual(manualOnly, [
            Paykit.PaymentOccurrence(
                request: Paykit.PaymentRequestScope(
                    counterparty: request.counterparty,
                    paymentRequestId: request.paymentRequestId
                ),
                billingPeriod: nil
            ),
        ])
        let log = harness.log.entries
        XCTAssertFalse(log.contains("beginPaymentExecution"))
        XCTAssertFalse(log.contains("payLightning"))
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal, [])
    }

    func testBlockedBeginRecordsAFailedOutcome() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setBeginDecision(.blocked(reason: .manualOnly))

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: AllowanceSdkMock.automaticAttemptId, outcome: .failed)])
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.failed])
        let log = harness.log.entries
        XCTAssertFalse(log.contains("consumePaymentList"))
        XCTAssertFalse(log.contains("prepareProof"))
        XCTAssertFalse(log.contains("payLightning"))
    }

    func testClaimFailureStaysManualBeforeAnyAcceptance() async throws {
        let harness = AllowanceHarness()
        await harness.payer.setClaimError(PaykitPaymentRequestError.requestUnavailable)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let log = harness.log.entries
        XCTAssertTrue(log.contains("claimForExecution"))
        XCTAssertFalse(log.contains("acceptPaymentRequestAutomatically"))
        XCTAssertFalse(log.contains("reserveAutomaticPayment"))
        XCTAssertFalse(log.contains("payLightning"))
    }

    func testRefusedAcceptanceDropsTheIntentButAnInterruptedOneKeepsIt() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        await harness.sdk.setAcceptError(PaykitError.Policy(code: "refused", context: "refused"))

        let refused = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(refused, .manual)
        var intents = await harness.payer.acceptanceIntents
        XCTAssertEqual(intents, [], "A refused Acceptance leaves nothing to reconcile")

        await harness.sdk.setAcceptError(PaykitError.Transport(code: "timeout", context: "interrupted"))
        let interrupted = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(interrupted, .manual)
        intents = await harness.payer.acceptanceIntents
        XCTAssertEqual(intents, [request.id], "An interrupted response may follow a committed Acceptance")
        XCTAssertFalse(harness.log.entries.contains("reserveAutomaticPayment"))
    }

    func testNodeRejectionBeforeRoutingReleasesThePaymentListAndRecordsAFailure() async throws {
        let harness = AllowanceHarness()
        await harness.payer.setLightningError(AllowanceMockError.unsupported)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.definitePreBroadcastFailure])
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: AllowanceSdkMock.automaticAttemptId, outcome: .failed)])
        XCTAssertTrue(harness.log.entries.contains("failLightningPayment"))
    }

    func testUncertainLightningSubmissionErrorKeepsTheReservation() async throws {
        let harness = AllowanceHarness()
        await harness.payer.setLightningError(AllowanceMockError.unsupported)
        await harness.payer.setLightningErrorIsDefinite(false)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .started)
        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.uncertain])
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: AllowanceSdkMock.automaticAttemptId, outcome: .unknown)])
    }

    func testSettlementDuringTheSendIsNotReplacedBySent() async throws {
        let harness = AllowanceHarness()
        let gate = await harness.payer.holdLightning()
        let request = try Fixtures.paymentRequest()
        await harness.executor.activate(identity: Fixtures.identityKey)

        let caller = Task { await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey) }
        await Self.waitUntil { harness.log.entries.contains("payLightning") }
        await harness.executor.lightningPaymentSettled(paymentHash: AllowanceHarness.paymentHash, succeeded: true)
        gate.open()
        _ = await caller.value

        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.succeeded])
    }

    func testRecoveryLeavesTheAttemptOfAPaymentInProgressAlone() async throws {
        let harness = AllowanceHarness()
        let gate = await harness.payer.holdLightning()
        let request = try Fixtures.paymentRequest()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(occurrences: [
            Fixtures.occurrence(
                requestId: request.paymentRequestId,
                attempts: [Fixtures.attemptRecord(id: AllowanceSdkMock.automaticAttemptId, status: .prepared)]
            ),
        ]))
        await harness.executor.activate(identity: Fixtures.identityKey)

        let caller = Task { await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey) }
        await Self.waitUntil { harness.log.entries.contains("payLightning") }
        await harness.executor.recover(identity: Fixtures.identityKey)
        let outcomesDuringTheSend = await harness.sdk.recordedOutcomes
        gate.open()
        _ = await caller.value

        XCTAssertEqual(outcomesDuringTheSend, [], "A node restart during the send must not fail the attempt being sent")
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.sent])
    }

    // MARK: Cancellation

    func testLightningPaymentStillStartsWhenItsCallerIsCancelledDuringTheSend() async throws {
        let harness = AllowanceHarness()
        let gate = await harness.payer.holdLightning()
        let request = try Fixtures.paymentRequest()

        let caller = Task { await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey) }
        await Self.waitUntil { harness.log.entries.contains("payLightning") }
        caller.cancel()
        gate.open()
        let result = await caller.value

        XCTAssertEqual(result, .started)
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.sent])
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [], "The settlement event, not the caller, records a Lightning outcome")
        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.uncertain])
    }

    func testOnchainAutoPaymentFeeIsNotSpentOutsideTheAllowance() async throws {
        let harness = AllowanceHarness(payment: AllowanceHarness.onchainPayment())

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        XCTAssertFalse(harness.log.entries.contains("claimForExecution"))
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [])
    }

    // MARK: Settlement and recovery

    func testLightningSettlementRecordsSuccessForTheJournaledAttempt() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(
                attemptId: "attempt-1",
                request: request,
                stage: .sent,
                paymentHash: AllowanceHarness.paymentHash
            )]),
            identity: Fixtures.identityKey
        )
        await harness.executor.activate(identity: Fixtures.identityKey)
        let events = AllowanceEventRecorder()

        await harness.executor.lightningPaymentSettled(paymentHash: String(repeating: "f", count: 64), succeeded: true)
        let outcomesForUnknownHash = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomesForUnknownHash, [])

        await harness.executor.lightningPaymentSettled(paymentHash: AllowanceHarness.paymentHash.uppercased(), succeeded: true)

        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: "attempt-1", outcome: .succeeded)])
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.succeeded])
        let paidEvents = events.events.filter {
            $0 == .paidAutomatically(counterparty: Fixtures.counterpartyKey, amountSats: 1000, paymentId: AllowanceHarness.paymentHash)
        }
        XCTAssertEqual(paidEvents.count, 1)
        XCTAssertEqual(harness.log.entries.filter { $0 == "payLightning" || $0 == "payOnchain" }, [])
    }

    func testExecutionStartupErrorReleasesTheReservation() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setBeginError(AllowanceMockError.unsupported)

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes, [Paykit.PaymentOutcomeReport(attemptId: AllowanceSdkMock.automaticAttemptId, outcome: .failed)])
        XCTAssertFalse(harness.log.entries.contains("payLightning"))
    }

    func testRefusedAcceptanceKeepsAnIntentTheManualFlowSaved() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        await harness.payer.seedAcceptanceIntent(request.id)
        await harness.sdk.setAcceptError(AllowanceMockError.unsupported)

        _ = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        let intents = await harness.payer.acceptanceIntents
        XCTAssertEqual(intents, [request.id])
        XCTAssertFalse(harness.log.entries.contains("discardAcceptanceIntent"))
    }

    func testRecoveryAnnouncesAnAutomaticPaymentItSettles() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-sent-paid", attempts: [Fixtures.attemptRecord(id: "sent-paid", status: .submitted)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "sent-paid", request: request, stage: .sent, paymentHash: paidHash)]),
            identity: Fixtures.identityKey
        )
        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: String(repeating: "0", count: 64))])
        let events = AllowanceEventRecorder()

        await harness.executor.recover(identity: Fixtures.identityKey)

        let paid = events.events.filter { $0 == .paidAutomatically(counterparty: Fixtures.counterpartyKey, amountSats: 1000, paymentId: paidHash) }
        XCTAssertEqual(paid.count, 1)
    }

    func testRecoveryAnnouncesAPaymentReconciliationAlreadySettled() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-settled", attempts: [Fixtures.attemptRecord(id: "settled", status: .succeeded)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "settled", request: request, stage: .sent, paymentHash: paidHash)]),
            identity: Fixtures.identityKey
        )
        let events = AllowanceEventRecorder()

        await harness.executor.recover(identity: Fixtures.identityKey)
        await harness.executor.recover(identity: Fixtures.identityKey)

        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.succeeded])
        let paid = events.events.filter { $0 == .paidAutomatically(counterparty: Fixtures.counterpartyKey, amountSats: 1000, paymentId: paidHash) }
        XCTAssertEqual(paid.count, 1)
    }

    func testSettlementAndRecoveryAnnounceOnePaymentOnce() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-sent", attempts: [Fixtures.attemptRecord(id: "sent", status: .submitted)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "sent", request: request, stage: .sent, paymentHash: paidHash)]),
            identity: Fixtures.identityKey
        )
        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: String(repeating: "0", count: 64))])
        await harness.executor.activate(identity: Fixtures.identityKey)
        let events = AllowanceEventRecorder()

        await harness.executor.lightningPaymentSettled(paymentHash: paidHash, succeeded: true)
        await harness.executor.recover(identity: Fixtures.identityKey)
        await harness.executor.lightningPaymentSettled(paymentHash: paidHash, succeeded: true)

        let paid = events.events.filter { $0 == .paidAutomatically(counterparty: Fixtures.counterpartyKey, amountSats: 1000, paymentId: paidHash) }
        XCTAssertEqual(paid.count, 1)
    }

    func testLimitCheckIgnoresAnExpiredAllowance() async throws {
        let harness = AllowanceHarness()
        let active = Fixtures.allowance(allowanceId: "active", perPaymentMaxSats: 500)
        let expired = Fixtures.allowance(allowanceId: "expired", perPaymentMaxSats: 5000, expiresAt: Fixtures.now.addingTimeInterval(-60))

        let exceeds = try await harness.executor.exceedsLimits(
            Fixtures.paymentRequest(),
            allowances: [active, expired],
            identity: Fixtures.identityKey
        )

        XCTAssertTrue(exceeds, "Only an allowance active now can take a request")
    }

    func testPaymentListReleasedBeforeBroadcastIsReleasedAgainOnlyForItsOwner() async throws {
        let harness = AllowanceHarness()
        await harness.payer.setLightningError(AllowanceMockError.unsupported)

        _ = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.definitePreBroadcastFailure])
        let owners = await harness.payer.releaseOwners
        XCTAssertEqual(
            owners,
            [AllowanceSdkMock.automaticAttemptId],
            "The failure record releases only a list this attempt still owns, so another payment's consumption is left alone"
        )
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.paymentListVersion), [nil])
    }

    func testFailedAutomaticPaymentReleasesThePaymentListItConsumed() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(
                attemptId: "sent", request: request, stage: .sent, paymentHash: AllowanceHarness.paymentHash, paymentListVersion: 7
            )]),
            identity: Fixtures.identityKey
        )
        await harness.executor.activate(identity: Fixtures.identityKey)

        await harness.executor.lightningPaymentSettled(paymentHash: AllowanceHarness.paymentHash, succeeded: false)

        let released = await harness.payer.releasedLists
        XCTAssertEqual(released, [.init(publicKey: Fixtures.counterpartyKey, version: 7, previousVersion: 6)])
    }

    func testRecoverySettlesARestoredSubmittedAttemptFromTheNode() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-restored", attempts: [Fixtures.attemptRecord(id: "restored", status: .submitted)]),
        ]))
        let captured = PaykitAllowanceLocalState(journal: [
            Self.journalEntry(attemptId: "restored", request: request, stage: .submitted, paymentHash: paidHash),
        ])
        try harness.store.seed(PaykitAllowanceStateBackup(captured).restored(), identity: Fixtures.identityKey)
        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: String(repeating: "0", count: 64))])

        await harness.executor.recover(identity: Fixtures.identityKey)

        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes.map(\.outcome), [.succeeded])
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.succeeded])
    }

    func testRecoveryLeavesARestoredAttemptOpenUntilTheNodeCanAnswer() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-restored", attempts: [Fixtures.attemptRecord(id: "restored", status: .submitted)]),
        ]))
        let captured = PaykitAllowanceLocalState(journal: [
            Self.journalEntry(attemptId: "restored", request: request, stage: .submitted, paymentHash: paidHash),
        ])
        try harness.store.seed(PaykitAllowanceStateBackup(captured).restored(), identity: Fixtures.identityKey)
        // A restore activates allowances before the node starts, so its payment history is not there yet.
        await harness.lookup.setStatuses([paidHash: .unavailable])

        await harness.executor.recover(identity: Fixtures.identityKey)

        let outcomesBeforeStart = await harness.sdk.recordedOutcomes
        XCTAssertTrue(outcomesBeforeStart.isEmpty)
        let journalBeforeStart = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journalBeforeStart.map(\.stage), [.submitted])

        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: String(repeating: "0", count: 64))])
        await harness.executor.recover(identity: Fixtures.identityKey)

        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes.map(\.outcome), [.succeeded])
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.succeeded])
    }

    func testPaymentListIsNotConsumedWhenItsVersionCannotBeJournaled() async {
        let harness = AllowanceHarness()
        await harness.payer.failSavesOnListRead(harness.store)

        _ = try? await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertFalse(harness.log.entries.contains("consumePaymentList"), "A restart must find every consumed list in the journal")
    }

    func testPaymentListIsNotConsumedWhenTheAttemptWasNeverJournaled() async {
        let harness = AllowanceHarness()
        await harness.sdk.failJournalAfterReservation(harness.store)

        _ = try? await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertFalse(journal.contains { $0.attemptId == AllowanceSdkMock.automaticAttemptId && $0.paymentListVersion != nil })
        XCTAssertFalse(
            harness.log.entries.contains("consumePaymentList"),
            "Later saves succeed, but recovery would not find this attempt, so its list must not be consumed"
        )
    }

    func testAutomaticPaymentConsumesThePaymentListAsItsAttempt() async throws {
        let harness = AllowanceHarness()

        _ = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        let owners = await harness.payer.consumeOwners
        XCTAssertEqual(owners, [AllowanceSdkMock.automaticAttemptId])
    }

    func testRecoveryRetriesAPaymentListReleaseThatCouldNotBeSaved() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-failed", attempts: [Fixtures.attemptRecord(id: "failed", status: .failed)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "failed", request: request, stage: .failed, paymentListVersion: 5)]),
            identity: Fixtures.identityKey
        )
        await harness.payer.setReleaseSucceeds(false)

        await harness.executor.recover(identity: Fixtures.identityKey)
        let kept = await harness.executor.localState(identity: Fixtures.identityKey).journal.map(\.paymentListVersion)
        await harness.payer.setReleaseSucceeds(true)
        await harness.executor.recover(identity: Fixtures.identityKey)
        await harness.executor.recover(identity: Fixtures.identityKey)

        XCTAssertEqual(kept, [5], "A release that could not be saved keeps the version for the next recovery")
        let owners = await harness.payer.releaseOwners
        XCTAssertEqual(owners, ["failed", "failed"], "Recovery retries once, as the attempt that consumed the list, then stops")
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.paymentListVersion), [nil])
    }

    func testRecoveryReleasesThePaymentListOfAnAttemptKilledBeforeSending() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-killed", attempts: [Fixtures.attemptRecord(id: "killed", status: .submitted)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "killed", request: request, stage: .submitted, paymentListVersion: 3)]),
            identity: Fixtures.identityKey
        )

        await harness.executor.recover(identity: Fixtures.identityKey)

        let released = await harness.payer.releasedLists
        XCTAssertEqual(released, [.init(publicKey: Fixtures.counterpartyKey, version: 3, previousVersion: 2)])
        let owners = await harness.payer.releaseOwners
        XCTAssertEqual(owners, ["killed"], "Only the attempt that consumed the list gives it back")
    }

    func testRecoveryReleasesThePaymentListOfAnAttemptReconciliationFailed() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-failed", attempts: [Fixtures.attemptRecord(id: "failed", status: .failed)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "failed", request: request, stage: .sent, paymentListVersion: 5)]),
            identity: Fixtures.identityKey
        )

        await harness.executor.recover(identity: Fixtures.identityKey)
        await harness.executor.recover(identity: Fixtures.identityKey)

        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.failed])
        let released = await harness.payer.releasedLists
        XCTAssertEqual(released, [.init(publicKey: Fixtures.counterpartyKey, version: 5, previousVersion: 4)])
    }

    func testRecoveryNeverReleasesAListASettlementReleasedWhileItWaited() async throws {
        let harness = AllowanceHarness()
        let first = try Fixtures.paymentRequest()
        let second = try Fixtures.paymentRequest(id: "550e8400-e29b-41d4-a716-446655440002")
        let secondHash = String(repeating: "2", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-a", attempts: [Fixtures.attemptRecord(id: "a", status: .failed)]),
            Fixtures.occurrence(requestId: "req-b", attempts: [Fixtures.attemptRecord(id: "b", status: .failed)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [
                Self.journalEntry(attemptId: "a", request: first, stage: .sent, paymentListVersion: 5),
                Self.journalEntry(attemptId: "b", request: second, stage: .sent, paymentHash: secondHash, paymentListVersion: 7),
            ]),
            identity: Fixtures.identityKey
        )
        await harness.executor.activate(identity: Fixtures.identityKey)
        let gate = await harness.payer.holdNextRelease()

        let recovery = Task { await harness.executor.recover(identity: Fixtures.identityKey) }
        await Self.waitUntil { harness.log.entries.contains("releaseConsumedPaymentList") }
        await harness.executor.lightningPaymentSettled(paymentHash: secondHash, succeeded: false)
        gate.open()
        await recovery.value

        let released = await harness.payer.releasedLists.map(\.version)
        XCTAssertEqual(released.filter { $0 == 7 }.count, 1, "The second attempt's list is released once, by the settlement")
    }

    func testSettlementNeverReleasesAListRecoveryReleasedWhileItRecorded() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-a", attempts: [Fixtures.attemptRecord(id: "a", status: .failed)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(
                attemptId: "a", request: request, stage: .sent, paymentHash: AllowanceHarness.paymentHash, paymentListVersion: 5
            )]),
            identity: Fixtures.identityKey
        )
        await harness.executor.activate(identity: Fixtures.identityKey)
        let gate = await harness.sdk.holdNextOutcome()

        let settlement = Task { await harness.executor.lightningPaymentSettled(paymentHash: AllowanceHarness.paymentHash, succeeded: false) }
        await Self.waitUntil { harness.log.entries.contains("recordPaymentOutcome") }
        await harness.executor.recover(identity: Fixtures.identityKey)
        gate.open()
        await settlement.value

        let released = await harness.payer.releasedLists.map(\.version)
        XCTAssertEqual(released, [5], "The list is released once, by recovery")
    }

    func testRecoveryNeverReleasesAListASettlementReleasedWhileItLookedUpThePayment() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-a", attempts: [Fixtures.attemptRecord(id: "a", status: .submitted)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(
                attemptId: "a", request: request, stage: .sent, paymentHash: AllowanceHarness.paymentHash, paymentListVersion: 5
            )]),
            identity: Fixtures.identityKey
        )
        await harness.lookup.setStatuses([AllowanceHarness.paymentHash: .failed])
        await harness.executor.activate(identity: Fixtures.identityKey)
        let gate = await harness.lookup.holdNextLookup()

        let recovery = Task { await harness.executor.recover(identity: Fixtures.identityKey) }
        await Self.waitUntil { harness.log.entries.contains("lightningStatus") }
        await harness.executor.lightningPaymentSettled(paymentHash: AllowanceHarness.paymentHash, succeeded: false)
        gate.open()
        await recovery.value

        let released = await harness.payer.releasedLists.map(\.version)
        XCTAssertEqual(released, [5], "The list is released once, by the settlement")
    }

    func testRecoveryReleasesThePaymentListOfAFailureThatCouldNotBeSaved() async throws {
        let harness = AllowanceHarness()
        await harness.payer.setLightningError(AllowanceMockError.unsupported)
        await harness.payer.failSavesOnNodeRejection(harness.store)

        _ = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        let listOutcomes = await harness.payer.paymentListOutcomes
        XCTAssertEqual(listOutcomes, [.definitePreBroadcastFailure])
        let releasedWhileSavesFail = await harness.payer.releasedLists
        XCTAssertEqual(releasedWhileSavesFail, [], "A failure that can't be saved leaves the release to the recovery that saves it")

        harness.store.restoreSaves()
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-a", attempts: [Fixtures.attemptRecord(id: AllowanceSdkMock.automaticAttemptId, status: .failed)]),
        ]))
        await harness.executor.recover(identity: Fixtures.identityKey)
        await harness.executor.recover(identity: Fixtures.identityKey)

        let released = await harness.payer.releasedLists
        XCTAssertEqual(released.count, 1, "Recovery releases the list once, from the journal")
    }

    func testRecoveryResolvesOpenAttemptsWithoutPayingAgain() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        let pendingHash = String(repeating: "2", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(requestId: "req-prepared", attempts: [Fixtures.attemptRecord(id: "prepared", status: .prepared)]),
            Fixtures.occurrence(requestId: "req-old-epoch", attempts: [Fixtures.attemptRecord(id: "old-epoch", status: .prepared, epoch: "epoch-0")]),
            Fixtures.occurrence(requestId: "req-never-sent", attempts: [Fixtures.attemptRecord(id: "never-sent", status: .submitted)]),
            Fixtures.occurrence(requestId: "req-sent-paid", attempts: [Fixtures.attemptRecord(id: "sent-paid", status: .submitted)]),
            Fixtures.occurrence(requestId: "req-sent-pending", attempts: [Fixtures.attemptRecord(id: "sent-pending", status: .submitted)]),
            Fixtures.occurrence(requestId: "req-done", attempts: [Fixtures.attemptRecord(id: "done", status: .succeeded)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [
                Self.journalEntry(attemptId: "prepared", request: request, stage: .prepared),
                Self.journalEntry(attemptId: "never-sent", request: request, stage: .submitted),
                Self.journalEntry(attemptId: "sent-paid", request: request, stage: .sent, paymentHash: paidHash),
                Self.journalEntry(attemptId: "sent-pending", request: request, stage: .sent, paymentHash: pendingHash),
            ]),
            identity: Fixtures.identityKey
        )
        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: String(repeating: "0", count: 64)), pendingHash: .pending])

        await harness.executor.recover(identity: Fixtures.identityKey)

        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: outcomes.map { ($0.attemptId, $0.outcome) }),
            ["prepared": .failed, "never-sent": .failed, "sent-paid": .succeeded, "sent-pending": .unknown]
        )
        XCTAssertEqual(outcomes.count, 4)
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: journal.map { ($0.attemptId, $0.stage) }),
            ["prepared": .failed, "never-sent": .failed, "sent-paid": .succeeded, "sent-pending": .unknown]
        )
        let payerCalls = await harness.payer.callCount
        XCTAssertEqual(payerCalls, 0, "Recovery must never touch the payer, so nothing is paid twice")
        XCTAssertEqual(harness.log.entries.filter { $0 == "payLightning" || $0 == "payOnchain" }, [])
        let reconciliations = await harness.sdk.reconciliations
        XCTAssertEqual(reconciliations.count, 0)
    }

    // MARK: Manual payments

    func testManualPaymentThrowsWhenTheRequestIsAlreadyRecorded() async throws {
        let harness = AllowanceHarness()
        await harness.executor.activate(identity: Fixtures.identityKey)
        await harness.sdk.setManualReservation(.blocked(reason: .paymentAlreadyRecorded))
        let request = try Fixtures.paymentRequest()

        do {
            _ = try await harness.executor.beginManualPayment(request, paymentEndpointIdentifier: Fixtures.lightningIdentifier)
            XCTFail("Expected alreadyRecorded")
        } catch PaykitAllowanceManualPaymentError.alreadyRecorded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let log = harness.log.entries
        XCTAssertFalse(log.contains("beginPaymentExecution"))
    }

    func testManualPaymentOfARequestNotPricedInBitcoinStaysOutOfTheLedger() async throws {
        let harness = AllowanceHarness()
        await harness.executor.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest(amount: "5.00", asset: PaykitAsset.usd.rawValue)

        let attemptId = try await harness.executor.beginManualPayment(request, paymentEndpointIdentifier: Fixtures.lightningIdentifier)

        XCTAssertNil(attemptId)
        XCTAssertFalse(harness.log.entries.contains("reserveManualPayment"))
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal, [])
    }

    func testManualPaymentIsJournaledAndSubmittedWhenReady() async throws {
        let harness = AllowanceHarness()
        await harness.executor.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest()

        let attemptId = try await harness.executor.beginManualPayment(request, paymentEndpointIdentifier: Fixtures.lightningIdentifier)

        XCTAssertEqual(attemptId, AllowanceSdkMock.manualAttemptId)
        let journal = await harness.executor.localState(identity: Fixtures.identityKey).journal
        XCTAssertEqual(journal.map(\.stage), [.submitted])
        XCTAssertEqual(journal.first?.isAutomatic, false)

        await harness.sdk.setManualReservation(.blocked(reason: .manualOnly))
        let blocked = try await harness.executor.beginManualPayment(request, paymentEndpointIdentifier: Fixtures.lightningIdentifier)
        XCTAssertNil(blocked)
    }

    func testRecoverySettlesAManualLightningPaymentRestoredFromABackupTakenBeforeTheSend() async throws {
        let harness = AllowanceHarness()
        await harness.executor.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "1", count: 64)
        let reserved = try await harness.executor.beginManualPayment(
            request,
            paymentEndpointIdentifier: Fixtures.lightningIdentifier,
            paymentHash: paidHash.uppercased()
        )
        let attemptId = try XCTUnwrap(reserved)
        let captured = await harness.executor.localState(identity: Fixtures.identityKey)
        XCTAssertEqual(captured.journal.map(\.stage), [.submitted])
        try harness.store.seed(PaykitAllowanceStateBackup(captured).restored(), identity: Fixtures.identityKey)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: [
            Fixtures.occurrence(
                requestId: request.paymentRequestId,
                attempts: [Fixtures.attemptRecord(id: attemptId, mode: .manual, allowanceId: nil, status: .submitted)],
                allowanceId: nil
            ),
        ]))
        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: String(repeating: "0", count: 64))])

        await harness.executor.recover(identity: Fixtures.identityKey)

        let outcomes = await harness.sdk.recordedOutcomes
        XCTAssertEqual(outcomes.map(\.outcome), [.succeeded])
    }

    // MARK: Trusted time and reconciliation

    func testTrustedTimeNeverMovesBackwards() async {
        let harness = AllowanceHarness()
        let start = Fixtures.now

        let first = await harness.executor.trustedTime(identity: Fixtures.identityKey)
        harness.clock.set(start.addingTimeInterval(-3600))
        let afterClockMovedBack = await harness.executor.trustedTime(identity: Fixtures.identityKey)
        harness.clock.set(start.addingTimeInterval(60))
        let afterClockMovedForward = await harness.executor.trustedTime(identity: Fixtures.identityKey)

        XCTAssertEqual(first, PaykitAllowanceTime.format(start))
        XCTAssertEqual(afterClockMovedBack, PaykitAllowanceTime.format(start))
        XCTAssertEqual(afterClockMovedForward, PaykitAllowanceTime.format(start.addingTimeInterval(60)))
        let stored = await harness.executor.localState(identity: Fixtures.identityKey).lastTrustedTime
        XCTAssertEqual(stored, start.addingTimeInterval(60))
    }

    func testMissingLedgerIsReconciledWithAnEmptyHistory() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setAccountingState(nil)

        let reconciled = try await harness.executor.ensureReconciled(identity: Fixtures.identityKey)
        _ = try await harness.executor.ensureReconciled(identity: Fixtures.identityKey)

        let reconciliations = await harness.sdk.reconciliations
        XCTAssertEqual(reconciliations.count, 1)
        let reconciliation = try XCTUnwrap(reconciliations.first)
        XCTAssertNil(reconciliation.expectedRevision)
        XCTAssertTrue(reconciliation.history.associations.isEmpty)
        XCTAssertTrue(reconciliation.history.occurrences.isEmpty)
        XCTAssertTrue(reconciliation.history.watermarks.isEmpty)
        XCTAssertEqual(reconciliation.outcomes, [])
        XCTAssertEqual(reconciliation.trustedTime, PaykitAllowanceTime.format(Fixtures.now))
        XCTAssertFalse(reconciled.requiresReconciliation)
    }

    func testLedgerThatRequiresReconciliationIsReconciledAtItsRevision() async throws {
        let harness = AllowanceHarness()
        let request = try Fixtures.paymentRequest()
        let paidHash = String(repeating: "3", count: 64)
        try await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 7, requiresReconciliation: true, occurrences: [
            Fixtures.occurrence(requestId: "req-prepared", attempts: [Fixtures.attemptRecord(id: "prepared", status: .prepared)]),
            Fixtures.occurrence(requestId: "req-sent-paid", attempts: [Fixtures.attemptRecord(id: "sent-paid", status: .submitted)]),
        ]))
        harness.store.seed(
            PaykitAllowanceLocalState(journal: [Self.journalEntry(attemptId: "sent-paid", request: request, stage: .sent, paymentHash: paidHash)]),
            identity: Fixtures.identityKey
        )
        await harness.lookup.setStatuses([paidHash: .succeeded(preimage: nil)])

        try await harness.executor.ensureReconciled(identity: Fixtures.identityKey)

        let reconciliations = await harness.sdk.reconciliations
        XCTAssertEqual(reconciliations.count, 1)
        let reconciliation = try XCTUnwrap(reconciliations.first)
        XCTAssertEqual(reconciliation.expectedRevision, 7)
        XCTAssertEqual(reconciliation.history.occurrences.flatMap(\.attempts).map(\.attemptId), ["prepared", "sent-paid"])
        XCTAssertEqual(reconciliation.outcomes, [
            Paykit.PaymentOutcomeReport(attemptId: "prepared", outcome: .failed),
            Paykit.PaymentOutcomeReport(attemptId: "sent-paid", outcome: .succeeded),
        ])
        let payerCalls = await harness.payer.callCount
        XCTAssertEqual(payerCalls, 0)
    }

    // MARK: Trusted time vs subscription clock offset

    func testAdmissionUsesInjectedTimeWhileSubscriptionClockIsOffset() async throws {
        snapshotAppDefaults(SubscriptionClock.offsetDaysKey)
        UserDefaults.standard.set(400, forKey: SubscriptionClock.offsetDaysKey)
        try XCTSkipUnless(SubscriptionClock.offsetDays() == 400, "The subscription clock offset is unavailable in this build")
        let harness = AllowanceHarness()
        try await harness.sdk.setAccountingState(Self.stateNearTheMonthlyCap())

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(
            result,
            .manual,
            "September's paid attempts must count; the subscription clock offset would have moved the window a year ahead"
        )
        let evaluatedTimes = await harness.sdk.evaluatedTrustedTimes
        XCTAssertEqual(evaluatedTimes, [PaykitAllowanceTime.format(Fixtures.now)])
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
    }

    // MARK: Manager

    @MainActor
    func testAcceptingAProposalNeverAnswersAnotherContactsProposalWithTheSameId() async throws {
        let harness = AllowanceHarness()
        let sharedId = Fixtures.otherAllowanceId
        let offer = try Fixtures.record(
            allowanceId: sharedId, localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(),
            proposedByMe: false, lastEventAt: "2026-09-02T10:00:00Z"
        )
        let ask = try Fixtures.record(
            allowanceId: sharedId, counterparty: Fixtures.otherCounterpartyKey, localRole: .allower, state: .proposed,
            terms: Fixtures.standardTerms(), proposedByMe: false, lastEventAt: "2026-09-01T10:00:00Z"
        )
        await harness.sdk.setRecords([offer, ask])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let presented = try XCTUnwrap(manager.proposalForPresentation())
        XCTAssertEqual(presented.role, .allower, "Only M's ask goes to the review sheet; C's offer is accepted by itself")
        XCTAssertEqual(presented.counterparty, Fixtures.otherCounterpartyKey)

        let offers = await manager.acceptOffersFromAllowers()

        XCTAssertEqual(offers.map(\.counterparty), [Fixtures.counterpartyKey])
        let accepted = await harness.sdk.acceptedCounterparties
        XCTAssertEqual(accepted, [Fixtures.counterpartyKey], "Accepting C's offer must not accept M's ask as payer")
        XCTAssertEqual(manager.proposalForPresentation()?.counterparty, Fixtures.otherCounterpartyKey, "M's ask still waits for the user")
    }

    @MainActor
    func testPresentingOneContactsProposalKeepsAnotherContactsProposalWithTheSameIdPresentable() async throws {
        let harness = AllowanceHarness()
        let sharedId = Fixtures.otherAllowanceId
        // Both are asks: an offer from an allower is accepted without the review sheet, so it is never presented.
        let askFromC = try Fixtures.record(
            allowanceId: sharedId, localRole: .allower, state: .proposed, terms: Fixtures.standardTerms(),
            proposedByMe: false, lastEventAt: "2026-09-02T10:00:00Z"
        )
        let askFromM = try Fixtures.record(
            allowanceId: sharedId, counterparty: Fixtures.otherCounterpartyKey, localRole: .allower, state: .proposed,
            terms: Fixtures.standardTerms(), proposedByMe: false, lastEventAt: "2026-09-01T10:00:00Z"
        )
        await harness.sdk.setRecords([askFromC, askFromM])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let first = try XCTUnwrap(manager.proposalForPresentation())
        await manager.markProposalPresented(first)

        let second = try XCTUnwrap(manager.proposalForPresentation())
        XCTAssertNotEqual(second.counterparty, first.counterparty)
    }

    @MainActor
    func testManagerPresentsEachGrantAsOneEntryWithItsLimitsAndLeavesInvalidHistoryOut() async throws {
        let harness = AllowanceHarness()
        let terms = try Fixtures.standardTerms()
        await harness.sdk.setRecords([
            Fixtures.record(allowanceId: Fixtures.walletAllowanceId, terms: terms),
            Fixtures.record(allowanceId: Fixtures.otherAllowanceId, counterparty: Fixtures.otherCounterpartyKey, terms: terms),
            Fixtures.record(allowanceId: "allowance-invalid", historyStatus: .invalid, terms: terms),
        ])
        let group = PaykitAllowanceLocalState.Group(
            id: "group-1",
            counterparty: Fixtures.counterpartyKey,
            limits: Fixtures.limits,
            allowanceIds: [Fixtures.walletAllowanceId],
            createdAt: Fixtures.now
        )
        harness.store.seed(PaykitAllowanceLocalState(groups: [group]), identity: Fixtures.identityKey)
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        let entries = manager.entries
        XCTAssertEqual(entries.map(\.id), ["group-1", "\(Fixtures.otherCounterpartyKey)/\(Fixtures.otherAllowanceId)"])
        let grant = try XCTUnwrap(entries.first)
        XCTAssertEqual(grant.allowances.map(\.allowanceId), [Fixtures.walletAllowanceId])
        XCTAssertEqual(grant.limits, Fixtures.limits)
        XCTAssertEqual(grant.counterparty, Fixtures.counterpartyKey)
        XCTAssertEqual(grant.role, .allower)
        XCTAssertEqual(grant.perPaymentMaxSats, 5000)
        XCTAssertEqual(grant.monthlyLimitSats, 50000)
        XCTAssertEqual(grant.status(at: Fixtures.now), .active)
        XCTAssertNil(entries.last?.limits)
        XCTAssertEqual(manager.entry(id: "group-1")?.primary.allowanceId, Fixtures.walletAllowanceId)
    }

    @MainActor
    func testManagerCoversRequestsFromTheGrantedIdentityOnly() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms(), lastEventAt: "2026-09-24T09:00:00Z")])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertTrue(try manager.coversRequest(Fixtures.paymentRequest()), "One Encrypted Link per identity: no folder is part of coverage")
        XCTAssertFalse(try manager.coversRequest(Fixtures.paymentRequest(counterparty: Fixtures.otherCounterpartyKey)))
    }

    @MainActor
    func testManagerKeepsEveryAutomaticPaymentPastTheJournalLimit() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms(), lastEventAt: "2026-09-24T09:00:00Z")])
        let paid = try (0 ..< 250).map { index in
            try Fixtures.occurrence(requestId: "req-\(index)", attempts: [Fixtures.attemptRecord(id: "paid-\(index)", status: .succeeded)])
        }
        let notPaid = try [
            Fixtures.occurrence(requestId: "req-failed", attempts: [Fixtures.attemptRecord(id: "failed", status: .failed)]),
            Paykit.PaymentOccurrenceRecord(
                key: Paykit.PaymentOccurrenceKey(
                    request: Paykit.PaymentAccountingScope(
                        localPublicKey: Fixtures.otherCounterpartyKey,
                        counterparty: Fixtures.counterpartyKey,
                        paymentRequestId: "req-other-identity"
                    ),
                    billingPeriod: nil
                ),
                disposition: .automatic,
                allowanceId: Fixtures.walletAllowanceId,
                associationRevision: 1,
                attempts: [Fixtures.attemptRecord(id: "other-identity", status: .succeeded)]
            ),
            Fixtures.occurrence(
                requestId: "req-manual",
                attempts: [Fixtures.attemptRecord(id: "manual", mode: .manual, allowanceId: nil, status: .succeeded)],
                allowanceId: nil
            ),
        ]
        await harness.sdk.setAccountingState(Fixtures.accountingState(revision: 4, occurrences: paid + notPaid))
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertEqual(manager.autoPaidRequestIds.count, 250, "The journal keeps only the newest 200 attempts; the SDK ledger keeps all")
        XCTAssertTrue(manager.autoPaidRequestIds.contains(PaykitPaymentRequest.ID(paymentRequestId: "req-0", counterparty: Fixtures.counterpartyKey)))
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertEqual(manager.autoPaidSats(for: entry), 250 * 1000)
    }

    @MainActor
    func testManagerLeavesABitcoinRequestWithoutALightningEndpointManual() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms(), lastEventAt: "2026-09-24T09:00:00Z")])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        let usdtOnly = try Fixtures.paymentRequest(
            conversion: .fixed(rates: [.init(asset: "usdt", value: "100000")]),
            acceptedEndpoints: [PublicPaykitService.MethodId.usdtArbitrum.rawValue]
        )
        let onchainOnly = try Fixtures.paymentRequest(acceptedEndpoints: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue])

        for request in [usdtOnly, onchainOnly] {
            XCTAssertFalse(manager.coversRequest(request), "An allowance pays over Lightning only")
            let isHandling = await manager.isAutomaticallyHandling(request)
            XCTAssertFalse(isHandling, "The request reaches the Payment Request sheet instead of waiting for a channel")
        }
        XCTAssertTrue(try manager.coversRequest(Fixtures.paymentRequest(acceptedEndpoints: [
            PublicPaykitService.MethodId.usdtArbitrum.rawValue, Fixtures.lightningIdentifier,
        ])))
    }

    @MainActor
    func testManagerLeavesRequestsNotPricedInBitcoinManual() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms(), lastEventAt: "2026-09-24T09:00:00Z")])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        let usdRequest = try Fixtures.paymentRequest(amount: "5.00", asset: PaykitAsset.usd.rawValue)
        XCTAssertFalse(usdRequest.isAllowancePayable)
        XCTAssertFalse(manager.coversRequest(usdRequest))
        let isHandling = await manager.isAutomaticallyHandling(usdRequest)
        XCTAssertFalse(isHandling, "A USD request reaches the Send sheet instead of waiting for an automatic payment")

        let convertedRequest = try Fixtures.paymentRequest(conversion: .fixed(rates: [.init(asset: "usdt", value: "100000")]))
        XCTAssertTrue(convertedRequest.isAllowancePayable, "A bitcoin request that also prices a USDT rail pays over bitcoin")
        XCTAssertTrue(manager.coversRequest(convertedRequest))
    }

    func testManualPaymentOverTheUsdtRailStaysOutOfTheLedger() async throws {
        let harness = AllowanceHarness()
        await harness.executor.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest(conversion: .fixed(rates: [.init(asset: "usdt", value: "100000")]))

        let attemptId = try await harness.executor.beginManualPayment(
            request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.usdtArbitrum.rawValue
        )

        XCTAssertNil(attemptId)
        XCTAssertFalse(harness.log.entries.contains("reserveManualPayment"))
    }

    @MainActor
    func testGrantsNameOnlyBitcoinPaymentEndpoints() {
        XCTAssertFalse(PaykitAllowanceManager.allowedPaymentEndpointIdentifiers.contains(PublicPaykitService.MethodId.usdtArbitrum.rawValue))
        XCTAssertTrue(PaykitAllowanceManager.allowedPaymentEndpointIdentifiers.contains(PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue))
    }

    // MARK: Granting

    @MainActor
    func testProposeWaitsForTheContactsLinkAndThenProposesOneAllowance() async throws {
        let harness = AllowanceHarness()
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        let contact = Fixtures.contact()

        for state in [Paykit.LinkedPeerState.notLinked, .linking, .recoveryRequired, .blocked] {
            await harness.sdk.setPeers([Fixtures.linkedPeer(state: state)])
            do {
                try await manager.propose(to: contact, limits: Fixtures.limits)
                XCTFail("Expected contactNotLinked while the link is \(state)")
            } catch PaykitAllowanceError.contactNotLinked {
                // expected
            }
        }
        var proposals = await harness.sdk.proposals
        XCTAssertEqual(proposals.count, 0, "A grant never reaches a contact that has no usable link")
        XCTAssertTrue(manager.entries.isEmpty)

        await harness.sdk.setPeers([Fixtures.linkedPeer(state: .linked)])
        try await manager.propose(to: contact, limits: Fixtures.limits)

        proposals = await harness.sdk.proposals
        XCTAssertEqual(proposals.count, 1, "One link per identity means one SDK Allowance")
        XCTAssertEqual(proposals.first?.counterparty, Fixtures.counterpartyKey)
        XCTAssertEqual(proposals.first?.localRole, .allower)
        XCTAssertEqual(proposals.first?.terms.perPaymentAmount()?.maximum(), "0.00005")
        XCTAssertEqual(proposals.first?.terms.allowedPaymentEndpointIdentifiers(), PaykitAllowanceManager.allowedPaymentEndpointIdentifiers)
        XCTAssertTrue(harness.log.entries.contains("processOutboundPrivateMessages"))
        let entry = try XCTUnwrap(manager.entries.first)
        XCTAssertEqual(entry.allowances.map(\.allowanceId), ["proposed-1"])
        XCTAssertEqual(entry.limits, Fixtures.limits)
        XCTAssertEqual(entry.status(at: Fixtures.now), .awaitingAnswer)
    }

    @MainActor
    func testProposeIgnoresALinkedPeerThatIsAnotherContact() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setPeers([Fixtures.linkedPeer(counterparty: Fixtures.otherCounterpartyKey, state: .linked)])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        do {
            try await manager.propose(to: Fixtures.contact(), limits: Fixtures.limits)
            XCTFail("Expected contactNotLinked")
        } catch PaykitAllowanceError.contactNotLinked {
            // expected
        }
        let proposals = await harness.sdk.proposals
        XCTAssertEqual(proposals.count, 0)
    }

    @MainActor
    func testManagerCoverageUsesInjectedTimeWhileSubscriptionClockIsOffset() async throws {
        snapshotAppDefaults(SubscriptionClock.offsetDaysKey)
        UserDefaults.standard.set(400, forKey: SubscriptionClock.offsetDaysKey)
        try XCTSkipUnless(SubscriptionClock.offsetDays() == 400, "The subscription clock offset is unavailable in this build")
        let harness = AllowanceHarness()
        let expiring = try Fixtures.customTerms(expiresAt: Fixtures.now.addingTimeInterval(30 * 24 * 60 * 60))
        await harness.sdk.setRecords([Fixtures.record(terms: expiring)])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertTrue(try manager.coversRequest(Fixtures.paymentRequest()))
        XCTAssertFalse(try manager.coversRequest(Fixtures.paymentRequest(counterparty: Fixtures.otherCounterpartyKey)))
    }

    @MainActor
    func testManagerLeavesRequestsCreatedBeforeAcceptanceManual() async throws {
        let harness = AllowanceHarness()
        let acceptedAt = "2026-09-24T11:30:00Z"
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms(), lastEventAt: acceptedAt)])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertFalse(try manager.coversRequest(Fixtures.paymentRequest(createdAt: "2026-09-24T11:00:00Z")))
        XCTAssertTrue(try manager.coversRequest(Fixtures.paymentRequest(createdAt: "2026-09-24T11:29:40Z")), "Within the clock tolerance")
        XCTAssertTrue(try manager.coversRequest(Fixtures.paymentRequest(createdAt: "2026-09-24T11:45:00Z")))
    }

    // MARK: Incoming offers

    @MainActor
    func testManagerAcceptsAnOfferFromTheAllowerWithoutAReviewSheet() async throws {
        let harness = AllowanceHarness()
        // The proposer took the allower role, so this wallet is the allowee.
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        XCTAssertNil(manager.proposalForPresentation(), "An offer from the allower never opens the review sheet")

        let accepted = await manager.acceptOffersFromAllowers()

        XCTAssertEqual(accepted.map(\.counterparty), [Fixtures.counterpartyKey])
        let acceptedIds = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIds, [Fixtures.walletAllowanceId])
        XCTAssertEqual(manager.entries.first?.status(at: Fixtures.now), .active)
        XCTAssertEqual(manager.entries.first?.role, .allowee)
        XCTAssertEqual(manager.entries.first?.canEnd, true, "The allowee can still end it")
        XCTAssertNil(manager.proposalForPresentation())

        let acceptedAgain = await manager.acceptOffersFromAllowers()
        XCTAssertTrue(acceptedAgain.isEmpty, "An accepted offer is not accepted or announced twice")
        let acceptedIdsAfter = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIdsAfter, [Fixtures.walletAllowanceId])
    }

    @MainActor
    func testManagerRetriesAFailedOfferAcceptanceAndAnnouncesItOnce() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        await harness.sdk.setAcceptAllowanceError(AllowanceMockError.unsupported)

        let failed = await manager.acceptOffersFromAllowers()

        XCTAssertTrue(failed.isEmpty, "A failed accept is not announced")
        XCTAssertEqual(manager.entries.first?.status(at: Fixtures.now), .awaitingMyAnswer, "The offer stays open for the next refresh")
        XCTAssertNil(manager.proposalForPresentation(), "A failed offer still never opens the review sheet")

        await harness.sdk.setAcceptAllowanceError(nil)
        let accepted = await manager.acceptOffersFromAllowers()
        let acceptedAgain = await manager.acceptOffersFromAllowers()

        XCTAssertEqual(accepted.map(\.counterparty), [Fixtures.counterpartyKey])
        XCTAssertTrue(acceptedAgain.isEmpty)
        let acceptedIds = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIds, [Fixtures.walletAllowanceId])
    }

    @MainActor
    func testManagerAcceptsAndAnnouncesOffersOnlyWhileTheSessionIsCurrent() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let paused = await manager.acceptOffersFromAllowers(canContinue: { false })

        XCTAssertTrue(paused.isEmpty)
        XCTAssertFalse(harness.log.entries.contains("acceptAllowance"), "No accept while the session is paused or gone")

        var checks = 0
        let wentInactiveDuringAccept = await manager.acceptOffersFromAllowers(canContinue: {
            checks += 1
            return checks == 1
        })

        XCTAssertEqual(
            wentInactiveDuringAccept.map(\.counterparty), [Fixtures.counterpartyKey],
            "An accept made before the app went inactive is still announced: the offer is no longer answerable afterwards"
        )
        let acceptedIds = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIds, [Fixtures.walletAllowanceId])
    }

    @MainActor
    func testManagerDoesNotAnnounceAnOfferAcceptedAfterTheSessionEnded() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let sessionEnded = await manager.acceptOffersFromAllowers(canAnnounce: { false })

        XCTAssertTrue(sessionEnded.isEmpty, "Sign-out, a profile switch or profile deletion mid-accept announces nothing")
        let acceptedIds = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIds, [Fixtures.walletAllowanceId])
    }

    @MainActor
    func testManagerAnnouncesAnOfferWhoseAcceptWasCutShortOnTheNextRefresh() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        await harness.sdk.setAcceptAllowanceErrorAfterCommit(CancellationError())

        let cutShort = await manager.acceptOffersFromAllowers()

        XCTAssertTrue(cutShort.isEmpty)
        let acceptedIds = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIds, [Fixtures.walletAllowanceId], "The SDK committed the accept before the call stopped")

        await harness.sdk.setAcceptAllowanceErrorAfterCommit(nil)
        let relaunched = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await relaunched.activate(identity: Fixtures.identityKey)
        let announced = await relaunched.acceptOffersFromAllowers()
        let announcedAgain = await relaunched.acceptOffersFromAllowers()

        XCTAssertEqual(announced.map(\.counterparty), [Fixtures.counterpartyKey], "The accepted offer is announced on the next refresh")
        XCTAssertTrue(announcedAgain.isEmpty, "and only once")
        let acceptedIdsAfter = await harness.sdk.acceptedAllowanceIds
        XCTAssertEqual(acceptedIdsAfter, [Fixtures.walletAllowanceId])
    }

    @MainActor
    func testManagerAnnouncesAnOfferWhoseMarkCouldNotBeSaved() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        harness.store.failSaves()

        let first = await manager.acceptOffersFromAllowers()
        harness.store.restoreSaves()
        let second = await manager.acceptOffersFromAllowers()

        XCTAssertEqual((first + second).map(\.counterparty), [Fixtures.counterpartyKey], "An offer accepted for the user is announced")
    }

    @MainActor
    func testManagerDoesNotAnnounceAnOfferAgainWhenClearingItsMarkFails() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        await harness.sdk.setAcceptAllowanceErrorAfterCommit(CancellationError())
        _ = await manager.acceptOffersFromAllowers()
        await harness.sdk.setAcceptAllowanceErrorAfterCommit(nil)
        let relaunched = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await relaunched.activate(identity: Fixtures.identityKey)

        harness.store.failSaves()
        let announced = await relaunched.acceptOffersFromAllowers()
        harness.store.restoreSaves()
        let announcedAgain = await relaunched.acceptOffersFromAllowers()

        XCTAssertEqual(announced.map(\.counterparty), [Fixtures.counterpartyKey])
        XCTAssertTrue(announcedAgain.isEmpty, "An offer already announced is not announced again")
        let marks = await harness.executor.localState(identity: Fixtures.identityKey).unannouncedOfferIds
        XCTAssertTrue(marks.isEmpty, "The next refresh retries the clear that failed")
    }

    @MainActor
    func testManagerForgetsWhatItAnnouncedWhenDeactivated() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)
        await harness.sdk.setAcceptAllowanceErrorAfterCommit(CancellationError())
        _ = await manager.acceptOffersFromAllowers()
        await harness.sdk.setAcceptAllowanceErrorAfterCommit(nil)
        let relaunched = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await relaunched.activate(identity: Fixtures.identityKey)
        harness.store.failSaves()
        let announced = await relaunched.acceptOffersFromAllowers()

        relaunched.deactivate()
        await relaunched.activate(identity: Fixtures.identityKey)
        let announcedAfterReactivation = await relaunched.acceptOffersFromAllowers()
        harness.store.restoreSaves()

        XCTAssertEqual(announced.map(\.counterparty), [Fixtures.counterpartyKey])
        XCTAssertEqual(
            announcedAfterReactivation.map(\.counterparty),
            [Fixtures.counterpartyKey],
            "A new session announces an offer whose mark is still stored"
        )
    }

    @MainActor
    func testAutomaticOfferAcceptanceKeepsAManualProposalWorking() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allowee, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        await harness.sdk.setPeers([Fixtures.linkedPeer(state: .linked)])
        let gate = AllowanceGate()
        await harness.sdk.setProposeGate(gate)
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let proposing = Task { @MainActor in try await manager.propose(to: Fixtures.contact(), limits: Fixtures.limits) }
        while !harness.log.entries.contains("proposeAllowance") {
            await Task.yield()
        }
        XCTAssertTrue(manager.isWorking)

        let accepted = await manager.acceptOffersFromAllowers()

        XCTAssertEqual(accepted.count, 1)
        XCTAssertTrue(manager.isWorking, "A background accept must not re-enable Save while a proposal is in flight")
        gate.open()
        try await proposing.value
        XCTAssertFalse(manager.isWorking)
    }

    @MainActor
    func testManagerLeavesAnAskFromTheAlloweeForTheReviewSheet() async throws {
        let harness = AllowanceHarness()
        // The proposer took the allowee role, so this wallet is the allower and pays: the user decides.
        try await harness.sdk.setRecords([
            Fixtures.record(localRole: .allower, state: .proposed, terms: Fixtures.standardTerms(), proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let accepted = await manager.acceptOffersFromAllowers()

        XCTAssertTrue(accepted.isEmpty)
        let acceptedIds = await harness.sdk.acceptedAllowanceIds
        XCTAssertTrue(acceptedIds.isEmpty)
        XCTAssertFalse(harness.log.entries.contains("acceptAllowance"))
        XCTAssertEqual(manager.proposalForPresentation()?.counterparty, Fixtures.counterpartyKey)
        XCTAssertEqual(manager.entries.first?.status(at: Fixtures.now), .awaitingMyAnswer)
    }

    @MainActor
    func testManagerNeverAcceptsAProposalItSentOrOneAlreadyAnswered() async throws {
        let harness = AllowanceHarness()
        let terms = try Fixtures.standardTerms()
        await harness.sdk.setRecords([
            Fixtures.record(allowanceId: "sent", localRole: .allower, state: .proposed, terms: terms, proposedByMe: true),
            Fixtures.record(allowanceId: "declined", localRole: .allowee, state: .rejected, terms: terms, proposedByMe: false),
            Fixtures.record(allowanceId: "ended", localRole: .allowee, state: .ended, terms: terms, proposedByMe: false),
        ])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })
        await manager.activate(identity: Fixtures.identityKey)

        let accepted = await manager.acceptOffersFromAllowers()

        XCTAssertTrue(accepted.isEmpty)
        XCTAssertFalse(harness.log.entries.contains("acceptAllowance"))
    }

    // MARK: Helpers

    @MainActor
    func testReceivedRequestWithoutAmountCeilingIsDropped() async throws {
        let harness = AllowanceHarness()
        // Valid for the SDK: an expiry alone satisfies "an amount ceiling or expiry".
        let uncapped = try Paykit.AllowanceTerms(
            asset: PaykitIssuerInterop.bitcoinAsset,
            perPaymentAmount: nil,
            periodLimits: [],
            lifetimeAmountLimit: nil,
            activeFrom: nil,
            expiresAt: "2100-01-01T00:00:00Z",
            allowedPaymentEndpointIdentifiers: nil
        )
        await harness.sdk.setRecords([Fixtures.record(state: .proposed, terms: uncapped, proposedByMe: false)])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now }, canPayNow: { true })
        await manager.activate(identity: Fixtures.identityKey)

        XCTAssertEqual(manager.entries, [])
        XCTAssertNil(PaykitAllowance(record: Fixtures.record(terms: uncapped, proposedByMe: false)))
        XCTAssertNotNil(PaykitAllowance(record: Fixtures.record(localRole: .allowee, terms: uncapped, proposedByMe: false)))
    }

    @MainActor
    func testManagerLeavesARequestWithUnknownCreationTimeManual() async throws {
        let harness = AllowanceHarness()
        try await harness.sdk.setRecords([Fixtures.record(terms: Fixtures.standardTerms())])
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now }, canPayNow: { true })
        await manager.activate(identity: Fixtures.identityKey)
        let request = try Fixtures.paymentRequest(createdAt: "not-a-timestamp")
        XCTAssertNil(request.createdAt)

        XCTAssertFalse(manager.coversRequest(request))
    }

    private static func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Three succeeded automatic payments this month total 49,500 sats of the 50,000 sat cap.
    private static func stateNearTheMonthlyCap() throws -> Paykit.AllowanceAccountingState {
        try Fixtures.accountingState(occurrences: [
            Fixtures.occurrence(requestId: "paid-1", attempts: [
                Fixtures.attemptRecord(id: "paid-1", amount: "0.0002", admittedAt: "2026-09-05T10:00:00Z", status: .succeeded),
            ]),
            Fixtures.occurrence(requestId: "paid-2", attempts: [
                Fixtures.attemptRecord(id: "paid-2", amount: "0.0002", admittedAt: "2026-09-12T10:00:00Z", status: .succeeded),
            ]),
            Fixtures.occurrence(requestId: "paid-3", attempts: [
                Fixtures.attemptRecord(id: "paid-3", amount: "0.000095", admittedAt: "2026-09-20T10:00:00Z", status: .succeeded),
            ]),
        ])
    }

    private static func journalEntry(
        attemptId: String,
        request: PaykitPaymentRequest,
        stage: PaykitAllowanceLocalState.Stage,
        paymentHash: String? = nil,
        paymentListVersion: UInt64? = nil
    ) -> PaykitAllowanceLocalState.JournalEntry {
        PaykitAllowanceLocalState.JournalEntry(
            attemptId: attemptId,
            isAutomatic: true,
            requestId: request.id,
            allowanceId: Fixtures.walletAllowanceId,
            amountSats: request.allowanceAmountSats,
            paymentEndpointIdentifier: Fixtures.lightningIdentifier,
            paymentHash: paymentHash,
            onchainAddress: nil,
            transactionId: nil,
            stage: stage,
            createdAt: Fixtures.now,
            paymentListVersion: paymentListVersion,
            previousPaymentListVersion: paymentListVersion.map { $0 - 1 }
        )
    }
}

// MARK: - Test doubles

private struct AllowanceHarness {
    static let paymentHash = String(repeating: "ab", count: 32)
    static let invoice = "lnbcrt10u1allowancetestinvoice"
    static let paymentAppId = "bitkit"

    let log = AllowanceCallLog()
    let store = AllowanceMemoryStore()
    let clock = AllowanceTestClock(PaykitAllowanceFixtures.now)
    let sdk: AllowanceSdkMock
    let payer: AllowancePayerMock
    let lookup: AllowanceLightningLookupMock
    let executor: PaykitAllowanceExecutor

    init(payment: PrivatePaykitAllowancePayment = Self.lightningPayment()) {
        sdk = AllowanceSdkMock(log: log)
        payer = AllowancePayerMock(log: log, payment: payment)
        lookup = AllowanceLightningLookupMock(log: log)
        let clock = clock
        executor = PaykitAllowanceExecutor(sdk: sdk, store: store, payer: payer, lightningLookup: lookup, now: { clock.now() })
    }

    static func candidate(blocked: Paykit.AllowanceAccountingBlock? = nil) -> Paykit.AllowanceCandidate {
        Paykit.AllowanceCandidate(
            allowanceId: PaykitAllowanceFixtures.walletAllowanceId,
            eligiblePaymentEndpointIdentifiers: [PaykitAllowanceFixtures.lightningIdentifier],
            blocked: blocked
        )
    }

    static let onchainAddress = "bcrt1qallowancetestaddress"

    static func onchainPayment() -> PrivatePaykitAllowancePayment {
        PrivatePaykitAllowancePayment(
            endpoint: PublicPaykitService.Endpoint(
                methodId: .bitcoinOnchainP2wpkh,
                value: onchainAddress,
                min: nil,
                max: nil,
                rawPayload: "{\"value\":\"\(onchainAddress)\"}"
            ),
            context: PrivatePaykitPaymentContext(
                paymentAppsByEndpoint: [PaykitAllowanceFixtures.onchainIdentifier: paymentAppId],
                paymentListVersion: 3
            ),
            lightningPaymentHash: nil,
            lightningInvoiceHasAmount: false
        )
    }

    static func lightningPayment() -> PrivatePaykitAllowancePayment {
        PrivatePaykitAllowancePayment(
            endpoint: PublicPaykitService.Endpoint(
                methodId: .bitcoinLightningBolt11,
                value: invoice,
                min: nil,
                max: nil,
                rawPayload: "{\"value\":\"\(invoice)\"}"
            ),
            context: PrivatePaykitPaymentContext(
                paymentAppsByEndpoint: [PaykitAllowanceFixtures.lightningIdentifier: paymentAppId],
                paymentListVersion: 3
            ),
            lightningPaymentHash: paymentHash,
            lightningInvoiceHasAmount: true
        )
    }
}

private final class AllowanceCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] {
        lock.withLock { storage }
    }

    func append(_ entry: String) {
        lock.withLock { storage.append(entry) }
    }
}

private final class AllowanceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func set(_ newDate: Date) {
        lock.withLock { date = newDate }
    }
}

private final class AllowanceMemoryStore: PaykitAllowanceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: PaykitAllowanceLocalState] = [:]
    private var savesFail = false
    private var savesFailOnceSpent = false
    private var failingSaves = 0

    func load(identity: String) throws -> PaykitAllowanceLocalState {
        lock.withLock { states[identity] ?? PaykitAllowanceLocalState() }
    }

    func save(_ state: PaykitAllowanceLocalState, identity: String) throws {
        try lock.withLock {
            if savesFail || (savesFailOnceSpent && states[identity]?.automaticSpends.isEmpty == false) {
                throw AllowanceMockError.unsupported
            }
            if failingSaves > 0 {
                failingSaves -= 1
                throw AllowanceMockError.unsupported
            }
            states[identity] = state
        }
    }

    func failSaves() {
        lock.withLock { savesFail = true }
    }

    /// Saves fail once an automatic spend is stored, so an attempt gets past its admission.
    func failSavesOnceSpent() {
        lock.withLock { savesFailOnceSpent = true }
    }

    func restoreSaves() {
        lock.withLock { savesFail = false }
    }

    func failNextSave() {
        lock.withLock { failingSaves = 1 }
    }

    func seed(_ state: PaykitAllowanceLocalState, identity: String) {
        lock.withLock { states[identity] = state }
    }
}

private final class AllowanceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PaykitAllowanceEvent] = []
    private var cancellable: AnyCancellable?

    init() {
        cancellable = PaykitAllowanceExecutor.eventPublisher.sink { [weak self] event in
            self?.append(event)
        }
    }

    var events: [PaykitAllowanceEvent] {
        lock.withLock { storage }
    }

    private func append(_ event: PaykitAllowanceEvent) {
        lock.withLock { storage.append(event) }
    }
}

/// A latch a test holds closed to stop a mocked payment mid-send.
private final class AllowanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private enum AllowanceMockError: Error {
    case unsupported
}

private actor AllowanceLightningLookupMock: PaykitLightningPaymentProofLookingUp {
    private let log: AllowanceCallLog
    private var statuses: [String: PaykitLightningPaymentProofStatus] = [:]

    init(log: AllowanceCallLog) {
        self.log = log
    }

    func setStatuses(_ statuses: [String: PaykitLightningPaymentProofStatus]) {
        self.statuses = statuses
    }

    private var lookupGate: AllowanceGate?

    func holdNextLookup() -> AllowanceGate {
        let gate = AllowanceGate()
        lookupGate = gate
        return gate
    }

    func status(paymentHash: String) async -> PaykitLightningPaymentProofStatus {
        log.append("lightningStatus")
        if let gate = lookupGate {
            lookupGate = nil
            await gate.wait()
        }
        return statuses[paymentHash.lowercased()] ?? .unknown
    }
}

private actor AllowancePayerMock: PaykitAllowancePaying {
    struct PreparedProof: Equatable {
        let appId: String
        let endpoint: String
        let allowanceId: String?
    }

    struct LightningPayment: Equatable {
        let bolt11: String
        let sats: UInt64?
    }

    private let log: AllowanceCallLog
    private let payment: PrivatePaykitAllowancePayment?
    private var resolveError: Error?
    private var claimError: Error?
    private var lightningError: Error?
    private var lightningGate: AllowanceGate?
    private var lightningErrorIsDefinite = true
    private(set) var callCount = 0
    private(set) var claimedRequestIds: [PaykitPaymentRequest.ID] = []
    private(set) var acceptanceIntents: [PaykitPaymentRequest.ID] = []
    private(set) var paymentListOutcomes: [PrivatePaymentListSendOutcome] = []
    private(set) var preparedProofs: [PreparedProof] = []
    private(set) var associatedPaymentHashes: [String] = []
    private(set) var lightningPayments: [LightningPayment] = []

    init(log: AllowanceCallLog, payment: PrivatePaykitAllowancePayment?) {
        self.log = log
        self.payment = payment
    }

    private func called(_ name: String) {
        callCount += 1
        log.append(name)
    }

    func setResolveError(_ error: Error?) {
        resolveError = error
    }

    func setClaimError(_ error: Error?) {
        claimError = error
    }

    func setLightningError(_ error: Error?) {
        lightningError = error
    }

    func setLightningErrorIsDefinite(_ definite: Bool) {
        lightningErrorIsDefinite = definite
    }

    /// Holds `payLightning` until the returned gate opens, so a test can act while the send is in progress.
    func holdLightning() -> AllowanceGate {
        let gate = AllowanceGate()
        lightningGate = gate
        return gate
    }

    func resolve(_ request: PaykitPaymentRequest, eligibleIdentifiers: [String]) async throws -> PrivatePaykitAllowancePayment? {
        called("resolve")
        if let resolveError {
            throw resolveError
        }
        return payment
    }

    private(set) var consumeOwners: [String] = []
    private var consumeError: Error?

    func setConsumeError(_ error: Error?) {
        consumeError = error
    }

    func consumePaymentList(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID,
        owner: String,
        expectedPreviousVersion: UInt64?
    ) async throws {
        called("consumePaymentList")
        if let consumeError {
            throw consumeError
        }
        consumeOwners.append(owner)
    }

    func resolvePaymentList(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID,
        outcome: PrivatePaymentListSendOutcome
    ) async {
        called("resolvePaymentList")
        paymentListOutcomes.append(outcome)
    }

    struct ReleasedList: Equatable {
        let publicKey: String
        let version: UInt64
        let previousVersion: UInt64?
    }

    private(set) var releasedLists: [ReleasedList] = []
    private(set) var releaseOwners: [String] = []
    private var releaseSucceeds = true

    func setReleaseSucceeds(_ succeeds: Bool) {
        releaseSucceeds = succeeds
    }

    private var storeFailingOnListRead: AllowanceMemoryStore?

    /// Fails journal saves from the read just before the list's version is journaled.
    func failSavesOnListRead(_ store: AllowanceMemoryStore) {
        storeFailingOnListRead = store
    }

    func consumedPaymentListVersion(publicKey: String) async -> UInt64? {
        storeFailingOnListRead?.failSaves()
        return nil
    }

    private var releaseGate: AllowanceGate?

    /// Holds the next list release until the returned gate opens.
    func holdNextRelease() -> AllowanceGate {
        let gate = AllowanceGate()
        releaseGate = gate
        return gate
    }

    func releaseConsumedPaymentList(publicKey: String, version: UInt64, previousVersion: UInt64?, owner: String) async -> Bool {
        called("releaseConsumedPaymentList")
        releasedLists.append(ReleasedList(publicKey: publicKey, version: version, previousVersion: previousVersion))
        releaseOwners.append(owner)
        if let gate = releaseGate {
            releaseGate = nil
            await gate.wait()
        }
        return releaseSucceeds
    }

    func claimForExecution(_ request: PaykitPaymentRequest) async throws {
        called("claimForExecution")
        if let claimError {
            throw claimError
        }
        claimedRequestIds.append(request.id)
    }

    func recordAcceptanceIntent(_ request: PaykitPaymentRequest, identity: String) async throws -> Bool {
        called("recordAcceptanceIntent")
        guard !acceptanceIntents.contains(request.id) else { return false }
        acceptanceIntents.append(request.id)
        return true
    }

    func seedAcceptanceIntent(_ id: PaykitPaymentRequest.ID) {
        acceptanceIntents.append(id)
    }

    func discardAcceptanceIntent(_ request: PaykitPaymentRequest, identity: String) async {
        called("discardAcceptanceIntent")
        acceptanceIntents.removeAll { $0 == request.id }
    }

    func ensurePaymentAllowed(_ request: PaykitPaymentRequest) async throws {
        called("ensurePaymentAllowed")
    }

    func prepareProof(_ request: PaykitPaymentRequest, paymentAppId: String, paymentEndpointIdentifier: String, allowanceId: String?) async throws {
        called("prepareProof")
        preparedProofs.append(PreparedProof(appId: paymentAppId, endpoint: paymentEndpointIdentifier, allowanceId: allowanceId))
    }

    func associateLightningPayment(_ request: PaykitPaymentRequest, paymentHash: String) async throws {
        called("associateLightningPayment")
        associatedPaymentHashes.append(paymentHash)
    }

    func payLightning(_ request: PaykitPaymentRequest, bolt11: String, sats: UInt64?) async throws {
        called("payLightning")
        lightningPayments.append(LightningPayment(bolt11: bolt11, sats: sats))
        if let lightningGate {
            await lightningGate.wait()
            // The real node call is cancellable, so a cancelled caller must not be able to stop the payment here.
            try Task.checkCancellation()
        }
        if let lightningError {
            throw lightningError
        }
    }

    private var storeFailingOnNodeRejection: AllowanceMemoryStore?

    func failSavesOnNodeRejection(_ store: AllowanceMemoryStore) {
        storeFailingOnNodeRejection = store
    }

    func failLightningPayment(paymentHash: String, submissionError: Error) async -> Bool {
        called("failLightningPayment")
        storeFailingOnNodeRejection?.failSaves()
        return lightningErrorIsDefinite
    }

    func cancelProofPreparation(_ request: PaykitPaymentRequest) async {
        called("cancelProofPreparation")
    }
}

private actor AllowanceSdkMock: PaykitAllowanceSdkHandling {
    static let automaticAttemptId = "attempt-1"
    static let manualAttemptId = "manual-1"

    private let log: AllowanceCallLog
    struct Proposal {
        let counterparty: String
        let localRole: Paykit.AllowanceLocalRole
        let terms: Paykit.AllowanceTerms
    }

    private var records: [Paykit.AllowanceRecord] = []
    private var peers: [LinkedPeerRecord] = []
    private var accountingState: Paykit.AllowanceAccountingState? = PaykitAllowanceFixtures.accountingState()
    private var queuedAccountingStates: [Paykit.AllowanceAccountingState?] = []
    private var candidates: [Paykit.AllowanceCandidate] = [AllowanceHarness.candidate()]
    private var automaticReservation: Paykit.PaymentAttemptDecision?
    private var manualReservation: Paykit.PaymentAttemptDecision?
    private var beginDecision: Paykit.PaymentAttemptDecision?
    private var beginError: Error?
    private var acceptError: Error?
    private var acceptAllowanceError: Error?
    private var proposeGate: AllowanceGate?
    private(set) var acceptedAllowanceIds: [String] = []
    private(set) var evaluatedTrustedTimes: [String] = []
    private(set) var selections: [Paykit.AllowanceSelectionInput] = []
    private(set) var acceptedEndpointIdentifiers: [String] = []
    private(set) var reservedAssociationRevisions: [UInt64] = []
    private(set) var recordedOutcomes: [Paykit.PaymentOutcomeReport] = []
    private(set) var reconciliations: [Paykit.AllowanceAccountingReconciliation] = []
    private(set) var manualOnlyOccurrences: [Paykit.PaymentOccurrence] = []
    private(set) var proposals: [Proposal] = []
    private(set) var acceptedCounterparties: [String] = []

    init(log: AllowanceCallLog) {
        self.log = log
    }

    func setRecords(_ records: [Paykit.AllowanceRecord]) {
        self.records = records
    }

    func setPeers(_ peers: [LinkedPeerRecord]) {
        self.peers = peers
    }

    func setAccountingState(_ state: Paykit.AllowanceAccountingState?) {
        accountingState = state
    }

    /// Served one per read, then the last one stays.
    func queueAccountingStates(_ states: [Paykit.AllowanceAccountingState?]) {
        queuedAccountingStates = states
    }

    func setCandidates(_ candidates: [Paykit.AllowanceCandidate]) {
        self.candidates = candidates
    }

    func setAutomaticReservation(_ decision: Paykit.PaymentAttemptDecision) {
        automaticReservation = decision
    }

    func setManualReservation(_ decision: Paykit.PaymentAttemptDecision) {
        manualReservation = decision
    }

    func setBeginDecision(_ decision: Paykit.PaymentAttemptDecision) {
        beginDecision = decision
    }

    func setAcceptError(_ error: Error?) {
        acceptError = error
    }

    func setAcceptAllowanceError(_ error: Error?) {
        acceptAllowanceError = error
    }

    func setProposeGate(_ gate: AllowanceGate?) {
        proposeGate = gate
    }

    func setBeginError(_ error: Error?) {
        beginError = error
    }

    func linkedPeers() async throws -> [LinkedPeerRecord] {
        log.append("linkedPeers")
        return peers
    }

    func listAllowances(filter: Paykit.AllowanceFilter) async throws -> [Paykit.AllowanceRecord] {
        log.append("listAllowances")
        return records
    }

    func proposeAllowance(
        counterparty: String,
        localRole: Paykit.AllowanceLocalRole,
        terms: Paykit.AllowanceTerms
    ) async throws -> Paykit.AllowanceRecord {
        log.append("proposeAllowance")
        if let proposeGate {
            await proposeGate.wait()
        }
        proposals.append(Proposal(counterparty: counterparty, localRole: localRole, terms: terms))
        let record = PaykitAllowanceFixtures.record(
            allowanceId: "proposed-\(proposals.count)",
            counterparty: counterparty,
            state: .proposed,
            terms: terms
        )
        records.append(record)
        return record
    }

    private var acceptAllowanceErrorAfterCommit: Error?

    func setAcceptAllowanceErrorAfterCommit(_ error: Error?) {
        acceptAllowanceErrorAfterCommit = error
    }

    func acceptAllowance(counterparty: String, allowanceId: String, expectedProposalStreamItemId: UInt64) async throws -> Paykit.AllowanceRecord {
        log.append("acceptAllowance")
        if let acceptAllowanceError {
            throw acceptAllowanceError
        }
        acceptedCounterparties.append(counterparty)
        guard let index = records.firstIndex(where: { $0.counterparty == counterparty && $0.allowanceId == allowanceId }) else {
            throw AllowanceMockError.unsupported
        }
        records[index].state = .accepted
        acceptedAllowanceIds.append(allowanceId)
        if let acceptAllowanceErrorAfterCommit {
            throw acceptAllowanceErrorAfterCommit
        }
        return records[index]
    }

    func rejectAllowance(counterparty: String, allowanceId: String) async throws -> Paykit.AllowanceRecord {
        log.append("rejectAllowance")
        throw AllowanceMockError.unsupported
    }

    func endAllowance(counterparty: String, allowanceId: String) async throws -> Paykit.AllowanceRecord {
        log.append("endAllowance")
        throw AllowanceMockError.unsupported
    }

    func receivePrivateMessages(counterparty: String) async throws -> Paykit.PrivateStreamIntakeReport {
        log.append("receivePrivateMessages")
        return Paykit.PrivateStreamIntakeReport(receiveBatchId: nil, streamItemIds: [], eventConflicts: [])
    }

    func processOutboundPrivateMessages(counterparty: String) async throws -> Paykit.OutboundPrivateSendReport {
        log.append("processOutboundPrivateMessages")
        return Paykit.OutboundPrivateSendReport(attempted: [], sent: [], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: [])
    }

    func allowanceAccountingState() async throws -> Paykit.AllowanceAccountingState? {
        log.append("allowanceAccountingState")
        if !queuedAccountingStates.isEmpty {
            accountingState = queuedAccountingStates.removeFirst()
        }
        return accountingState
    }

    func reconcileAllowanceAccounting(_ reconciliation: Paykit.AllowanceAccountingReconciliation) async throws -> Paykit.AllowanceAccountingState {
        log.append("reconcileAllowanceAccounting")
        reconciliations.append(reconciliation)
        let reconciled = Paykit.AllowanceAccountingState(
            revision: (reconciliation.expectedRevision ?? 0) + 1,
            epoch: accountingState?.epoch ?? "epoch-1",
            requiresReconciliation: false,
            history: reconciliation.history
        )
        accountingState = reconciled
        return reconciled
    }

    func evaluateAllowanceCandidates(scope: Paykit.PaymentRequestScope, trustedTime: String) async throws -> [Paykit.AllowanceCandidate] {
        log.append("evaluateAllowanceCandidates")
        evaluatedTrustedTimes.append(trustedTime)
        return candidates
    }

    func acceptPaymentRequestAutomatically(
        scope: Paykit.PaymentRequestScope,
        selection: Paykit.AllowanceSelectionInput,
        checks: Paykit.PaymentExecutionChecks
    ) async throws -> Paykit.AllowanceAssociationRecord {
        log.append("acceptPaymentRequestAutomatically")
        if let acceptError {
            throw acceptError
        }
        selections.append(selection)
        acceptedEndpointIdentifiers.append(checks.paymentEndpointIdentifier)
        return Paykit.AllowanceAssociationRecord(
            request: PaykitAllowanceFixtures.accountingScope(scope.paymentRequestId),
            revisions: [
                Paykit.AllowanceAssociationRevision(
                    revision: 1,
                    allowanceId: selection.allowanceId,
                    effectiveFrom: nil,
                    authorizationId: nil,
                    authorizedAt: selection.trustedTime
                ),
            ]
        )
    }

    private var storeFailingJournal: AllowanceMemoryStore?

    /// Fails the next journal save, the one that records the attempt this reservation returns.
    func failJournalAfterReservation(_ store: AllowanceMemoryStore) {
        storeFailingJournal = store
    }

    func reserveAutomaticPayment(
        occurrence: Paykit.PaymentOccurrence,
        expectedAssociationRevision: UInt64,
        checks: Paykit.PaymentExecutionChecks
    ) async throws -> Paykit.PaymentAttemptDecision {
        log.append("reserveAutomaticPayment")
        storeFailingJournal?.failNextSave()
        storeFailingJournal = nil
        reservedAssociationRevisions.append(expectedAssociationRevision)
        if let automaticReservation {
            return automaticReservation
        }
        return try .ready(attempt: PaykitAllowanceFixtures.attemptRecord(
            id: Self.automaticAttemptId,
            admittedAt: checks.trustedTime,
            status: .prepared
        ))
    }

    func reserveManualPayment(occurrence: Paykit.PaymentOccurrence, checks: Paykit.PaymentExecutionChecks) async throws -> Paykit
        .PaymentAttemptDecision
    {
        log.append("reserveManualPayment")
        if let manualReservation {
            return manualReservation
        }
        return try .ready(attempt: PaykitAllowanceFixtures.attemptRecord(
            id: Self.manualAttemptId,
            mode: .manual,
            allowanceId: nil,
            admittedAt: checks.trustedTime,
            status: .prepared
        ))
    }

    func beginPaymentExecution(attemptId: String, checks: Paykit.PaymentExecutionChecks) async throws -> Paykit.PaymentAttemptDecision {
        log.append("beginPaymentExecution")
        if let beginError {
            throw beginError
        }
        if let beginDecision {
            return beginDecision
        }
        return try .ready(attempt: PaykitAllowanceFixtures.attemptRecord(id: attemptId, admittedAt: checks.trustedTime, status: .submitted))
    }

    private var outcomeGate: AllowanceGate?

    func holdNextOutcome() -> AllowanceGate {
        let gate = AllowanceGate()
        outcomeGate = gate
        return gate
    }

    func recordPaymentOutcome(_ report: Paykit.PaymentOutcomeReport) async throws -> Paykit.PaymentAttemptRecord {
        log.append("recordPaymentOutcome")
        recordedOutcomes.append(report)
        if let gate = outcomeGate {
            outcomeGate = nil
            await gate.wait()
        }
        let status: Paykit.PaymentExecutionStatus = switch report.outcome {
        case .succeeded: .succeeded
        case .failed: .failed
        case .unknown: .unknown
        }
        return try PaykitAllowanceFixtures.attemptRecord(id: report.attemptId, status: status)
    }

    func markPaymentManualOnly(occurrence: Paykit.PaymentOccurrence) async throws -> Paykit.PaymentOccurrenceRecord {
        log.append("markPaymentManualOnly")
        manualOnlyOccurrences.append(occurrence)
        return Paykit.PaymentOccurrenceRecord(
            key: Paykit.PaymentOccurrenceKey(
                request: PaykitAllowanceFixtures.accountingScope(occurrence.request.paymentRequestId),
                billingPeriod: nil
            ),
            disposition: .manualOnly,
            allowanceId: nil,
            associationRevision: nil,
            attempts: []
        )
    }
}
