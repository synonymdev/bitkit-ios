@testable import Bitkit
import Combine
import Foundation
import Paykit
import XCTest

final class PaykitAllowanceExecutorTests: XCTestCase {
    private typealias Fixtures = PaykitAllowanceFixtures

    private static let admissionCalls = [
        "evaluateAllowanceCandidates",
        "acceptPaymentRequestAutomatically",
        "reserveAutomaticPayment",
        "receivePrivateMessages",
        "beginPaymentExecution",
        "consumePaymentList",
        "prepareProof",
        "associateLightningPayment",
        "payLightning",
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
            [Fixtures.allowance(receiverPath: PaykitReceiverPath.server)],
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
        XCTAssertEqual(preparedProofs, [.init(endpoint: Fixtures.lightningIdentifier, allowanceId: Fixtures.walletAllowanceId)])
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

    func testBlockedReservationMarksThePaymentManualOnly() async throws {
        let harness = AllowanceHarness()
        await harness.sdk.setAutomaticReservation(.blocked(reason: .sharedRule(code: "period_amount_limit_exceeded")))
        let request = try Fixtures.paymentRequest()

        let result = await harness.executor.autoPay(request, allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual)
        let manualOnly = await harness.sdk.manualOnlyOccurrences
        XCTAssertEqual(manualOnly, [
            Paykit.PaymentOccurrence(
                request: Paykit.PaymentRequestScope(
                    counterparty: request.counterparty,
                    counterpartyReceiverPath: request.counterpartyReceiverPath,
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
        let paid = await harness.executor.succeededAutomaticPayments(identity: Fixtures.identityKey)
        XCTAssertEqual(paid.map(\.attemptId), ["attempt-1"])
        let paidEvents = events.events.filter {
            $0 == .paidAutomatically(counterparty: Fixtures.counterpartyKey, amountSats: 1000, paymentId: AllowanceHarness.paymentHash)
        }
        XCTAssertEqual(paidEvents.count, 1)
        XCTAssertEqual(harness.log.entries.filter { $0 == "payLightning" || $0 == "payOnchain" }, [])
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

    // MARK: Trusted time vs demo clock

    func testAdmissionUsesInjectedTimeWhileDemoClockIsOffset() async throws {
        snapshotAppDefaults(DemoClock.offsetDaysKey)
        UserDefaults.standard.set(400, forKey: DemoClock.offsetDaysKey)
        try XCTSkipUnless(DemoClock.offsetDays() == 400, "The demo clock is unavailable in this build")
        let harness = AllowanceHarness()
        try await harness.sdk.setAccountingState(Self.stateNearTheMonthlyCap())

        let result = try await harness.executor.autoPay(Fixtures.paymentRequest(), allowances: [Fixtures.allowance()], identity: Fixtures.identityKey)

        XCTAssertEqual(result, .manual, "September's paid attempts must count; the demo clock would have moved the window a year ahead")
        let evaluatedTimes = await harness.sdk.evaluatedTrustedTimes
        XCTAssertEqual(evaluatedTimes, [PaykitAllowanceTime.format(Fixtures.now)])
        XCTAssertFalse(harness.log.entries.contains("acceptPaymentRequestAutomatically"))
    }

    // MARK: Manager

    @MainActor
    func testManagerGroupsOneGrantAcrossLinksWithTheWalletLinkAsPrimary() async throws {
        let harness = AllowanceHarness()
        let terms = try Fixtures.standardTerms()
        await harness.sdk.setRecords([
            Fixtures.record(allowanceId: Fixtures.serverAllowanceId, receiverPath: PaykitReceiverPath.server, terms: terms),
            Fixtures.record(allowanceId: Fixtures.walletAllowanceId, receiverPath: PaykitReceiverPath.wallet, terms: terms),
            Fixtures.record(allowanceId: "allowance-other", counterparty: Fixtures.otherCounterpartyKey, terms: terms),
            Fixtures.record(allowanceId: "allowance-invalid", historyStatus: .invalid, terms: terms),
        ])
        let group = PaykitAllowanceLocalState.Group(
            id: "group-1",
            counterparty: Fixtures.counterpartyKey,
            limits: Fixtures.limits,
            allowanceIds: [Fixtures.walletAllowanceId, Fixtures.serverAllowanceId],
            createdAt: Fixtures.now
        )
        harness.store.seed(PaykitAllowanceLocalState(groups: [group]), identity: Fixtures.identityKey)
        let manager = PaykitAllowanceManager(sdk: harness.sdk, executor: harness.executor, now: { PaykitAllowanceFixtures.now })

        await manager.activate(identity: Fixtures.identityKey)

        let entries = manager.entries
        XCTAssertEqual(entries.map(\.id), ["group-1", "allowance-other"])
        let grouped = try XCTUnwrap(entries.first)
        XCTAssertEqual(grouped.allowances.map(\.allowanceId), [Fixtures.serverAllowanceId, Fixtures.walletAllowanceId])
        XCTAssertEqual(grouped.primary.allowanceId, Fixtures.walletAllowanceId)
        XCTAssertEqual(grouped.primary.counterpartyReceiverPath, PaykitReceiverPath.wallet)
        XCTAssertEqual(grouped.limits, Fixtures.limits)
        XCTAssertEqual(grouped.counterparty, Fixtures.counterpartyKey)
        XCTAssertEqual(grouped.role, .allower)
        XCTAssertEqual(grouped.perPaymentMaxSats, 5000)
        XCTAssertEqual(grouped.monthlyLimitSats, 50000)
        XCTAssertEqual(grouped.status(at: Fixtures.now), .active)
        XCTAssertNil(entries.last?.limits)
        XCTAssertEqual(manager.entry(id: "group-1")?.primary.allowanceId, Fixtures.walletAllowanceId)
    }

    @MainActor
    func testManagerCoverageUsesInjectedTimeWhileDemoClockIsOffset() async throws {
        snapshotAppDefaults(DemoClock.offsetDaysKey)
        UserDefaults.standard.set(400, forKey: DemoClock.offsetDaysKey)
        try XCTSkipUnless(DemoClock.offsetDays() == 400, "The demo clock is unavailable in this build")
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

    // MARK: Helpers

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
        paymentHash: String? = nil
    ) -> PaykitAllowanceLocalState.JournalEntry {
        PaykitAllowanceLocalState.JournalEntry(
            attemptId: attemptId,
            isAutomatic: true,
            requestId: request.id,
            allowanceId: Fixtures.walletAllowanceId,
            amountSats: request.amountSats,
            paymentEndpointIdentifier: Fixtures.lightningIdentifier,
            paymentHash: paymentHash,
            onchainAddress: nil,
            transactionId: nil,
            stage: stage,
            createdAt: Fixtures.now
        )
    }
}

// MARK: - Test doubles

private struct AllowanceHarness {
    static let paymentHash = String(repeating: "ab", count: 32)
    static let invoice = "lnbcrt10u1allowancetestinvoice"

    let log = AllowanceCallLog()
    let store = AllowanceMemoryStore()
    let clock = AllowanceTestClock(PaykitAllowanceFixtures.now)
    let sdk: AllowanceSdkMock
    let payer: AllowancePayerMock
    let lookup: AllowanceLightningLookupMock
    let executor: PaykitAllowanceExecutor

    init() {
        sdk = AllowanceSdkMock(log: log)
        payer = AllowancePayerMock(log: log, payment: Self.lightningPayment())
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

    static func lightningPayment() -> PrivatePaykitAllowancePayment {
        PrivatePaykitAllowancePayment(
            endpoint: PublicPaykitService.Endpoint(
                methodId: .bitcoinLightningBolt11,
                value: invoice,
                min: nil,
                max: nil,
                rawPayload: "{\"value\":\"\(invoice)\"}"
            ),
            context: PrivatePaykitPaymentContext(receiverPath: PaykitReceiverPath.wallet, paymentListVersion: 3),
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

    func load(identity: String) throws -> PaykitAllowanceLocalState {
        lock.withLock { states[identity] ?? PaykitAllowanceLocalState() }
    }

    func save(_ state: PaykitAllowanceLocalState, identity: String) throws {
        lock.withLock { states[identity] = state }
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

    func status(paymentHash: String) async -> PaykitLightningPaymentProofStatus {
        log.append("lightningStatus")
        return statuses[paymentHash.lowercased()] ?? .unknown
    }
}

private actor AllowancePayerMock: PaykitAllowancePaying {
    struct PreparedProof: Equatable {
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
    private(set) var callCount = 0
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

    func resolve(_ request: PaykitPaymentRequest, eligibleIdentifiers: [String]) async throws -> PrivatePaykitAllowancePayment? {
        called("resolve")
        if let resolveError { throw resolveError }
        return payment
    }

    func consumePaymentList(publicKey: String, context: PrivatePaykitPaymentContext) async throws {
        called("consumePaymentList")
    }

    func prepareProof(_ request: PaykitPaymentRequest, paymentEndpointIdentifier: String, allowanceId: String?) async throws {
        called("prepareProof")
        preparedProofs.append(PreparedProof(endpoint: paymentEndpointIdentifier, allowanceId: allowanceId))
    }

    func associateLightningPayment(_ request: PaykitPaymentRequest, paymentHash: String) async throws {
        called("associateLightningPayment")
        associatedPaymentHashes.append(paymentHash)
    }

    func markOnchainPaymentStarted(_ request: PaykitPaymentRequest, address: String) async throws {
        called("markOnchainPaymentStarted")
    }

    func payLightning(bolt11: String, sats: UInt64?) async throws {
        called("payLightning")
        lightningPayments.append(LightningPayment(bolt11: bolt11, sats: sats))
    }

    func payOnchain(address: String, sats: UInt64) async throws -> String {
        called("payOnchain")
        return String(repeating: "c", count: 64)
    }

    func completeOnchainPayment(_ request: PaykitPaymentRequest, txid: String, paymentEndpointIdentifier: String) async {
        called("completeOnchainPayment")
    }

    func failLightningPayment(paymentHash: String) async {
        called("failLightningPayment")
    }

    func cancelProofPreparation(_ request: PaykitPaymentRequest) async {
        called("cancelProofPreparation")
    }
}

private actor AllowanceSdkMock: PaykitAllowanceSdkHandling {
    static let automaticAttemptId = "attempt-1"
    static let manualAttemptId = "manual-1"

    private let log: AllowanceCallLog
    private var records: [Paykit.AllowanceRecord] = []
    private var accountingState: Paykit.AllowanceAccountingState? = PaykitAllowanceFixtures.accountingState()
    private var candidates: [Paykit.AllowanceCandidate] = [AllowanceHarness.candidate()]
    private var automaticReservation: Paykit.PaymentAttemptDecision?
    private var manualReservation: Paykit.PaymentAttemptDecision?
    private var beginDecision: Paykit.PaymentAttemptDecision?
    private(set) var evaluatedTrustedTimes: [String] = []
    private(set) var selections: [Paykit.AllowanceSelectionInput] = []
    private(set) var acceptedEndpointIdentifiers: [String] = []
    private(set) var reservedAssociationRevisions: [UInt64] = []
    private(set) var recordedOutcomes: [Paykit.PaymentOutcomeReport] = []
    private(set) var reconciliations: [Paykit.AllowanceAccountingReconciliation] = []
    private(set) var manualOnlyOccurrences: [Paykit.PaymentOccurrence] = []

    init(log: AllowanceCallLog) {
        self.log = log
    }

    func setRecords(_ records: [Paykit.AllowanceRecord]) {
        self.records = records
    }

    func setAccountingState(_ state: Paykit.AllowanceAccountingState?) {
        accountingState = state
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

    func linkedPeers() async throws -> [LinkedPeerRecord] {
        log.append("linkedPeers")
        return []
    }

    func listAllowances(filter: Paykit.AllowanceFilter) async throws -> [Paykit.AllowanceRecord] {
        log.append("listAllowances")
        return records
    }

    func proposeAllowance(
        counterparty: String,
        counterpartyReceiverPath: String,
        localRole: Paykit.AllowanceLocalRole,
        terms: Paykit.AllowanceTerms
    ) async throws -> Paykit.AllowanceRecord {
        log.append("proposeAllowance")
        throw AllowanceMockError.unsupported
    }

    func acceptAllowance(counterparty: String, counterpartyReceiverPath: String, allowanceId: String) async throws -> Paykit.AllowanceRecord {
        log.append("acceptAllowance")
        throw AllowanceMockError.unsupported
    }

    func rejectAllowance(counterparty: String, counterpartyReceiverPath: String, allowanceId: String) async throws -> Paykit.AllowanceRecord {
        log.append("rejectAllowance")
        throw AllowanceMockError.unsupported
    }

    func endAllowance(counterparty: String, counterpartyReceiverPath: String, allowanceId: String) async throws -> Paykit.AllowanceRecord {
        log.append("endAllowance")
        throw AllowanceMockError.unsupported
    }

    func receivePrivateMessages(counterparty: String, counterpartyReceiverPath: String) async throws -> Paykit.PrivateStreamIntakeReport {
        log.append("receivePrivateMessages")
        return Paykit.PrivateStreamIntakeReport(receiveBatchId: nil, streamItemIds: [], eventConflicts: [])
    }

    func processOutboundPrivateMessages(counterparty: String, counterpartyReceiverPath: String) async throws -> Paykit.OutboundPrivateSendReport {
        log.append("processOutboundPrivateMessages")
        return Paykit.OutboundPrivateSendReport(attempted: [], sent: [], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: [])
    }

    func allowanceAccountingState() async throws -> Paykit.AllowanceAccountingState? {
        log.append("allowanceAccountingState")
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

    func reserveAutomaticPayment(
        occurrence: Paykit.PaymentOccurrence,
        expectedAssociationRevision: UInt64,
        checks: Paykit.PaymentExecutionChecks
    ) async throws -> Paykit.PaymentAttemptDecision {
        log.append("reserveAutomaticPayment")
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
        if let beginDecision {
            return beginDecision
        }
        return try .ready(attempt: PaykitAllowanceFixtures.attemptRecord(id: attemptId, admittedAt: checks.trustedTime, status: .submitted))
    }

    func recordPaymentOutcome(_ report: Paykit.PaymentOutcomeReport) async throws -> Paykit.PaymentAttemptRecord {
        log.append("recordPaymentOutcome")
        recordedOutcomes.append(report)
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
