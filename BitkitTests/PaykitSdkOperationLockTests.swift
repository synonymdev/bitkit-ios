@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkOperationLockTests: XCTestCase {
    private actor Recorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    func testInteractiveWorkOvertakesOnlyQueuedPublicationWithBoundedFairness() async throws {
        try await assertQueuedOrder(
            priorities: [.background, .background, .interactive, .interactive, .interactive, .interactive],
            expected: [2, 3, 4, 0, 5, 1]
        )
    }

    func testInteractiveWorkCannotCrossAnOrderedOperation() async throws {
        try await assertQueuedOrder(
            priorities: [.background, .interactive, .ordered, .background, .interactive],
            expected: [1, 0, 2, 4, 3]
        )
    }

    func testCancelledInteractiveWorkDoesNotExecuteOrBlockPublication() async throws {
        try await assertQueuedOrder(
            priorities: [.background, .interactive],
            expected: [0],
            cancelIndex: 1
        )
    }

    func testCapabilitySyncPriorityPreservesOrderedWorkAndOnlyOvertakesQueuedBackgroundWork() async throws {
        let operations: [(PaykitSdkService) async throws -> Void] = [
            { _ = try await $0.receivePrivateMessagesFromLinkedPeers(priority: .background) },
            { _ = try await $0.ensureLinkWithPeer("peer", priority: .background) },
        ]
        let cases: [(priority: PaykitSdkOperationLock.Priority?, orderedBarrier: Bool, expected: [String])] = [
            (nil, false, ["active", "intake", "publish"]),
            (.interactive, false, ["active", "publish", "intake"]),
            (.interactive, true, ["active", "intake", "ordered", "publish"]),
        ]
        for operation in operations {
            for testCase in cases {
                let recorder = Recorder()
                let (gate, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                let started = expectation(description: "Active SDK operation started")
                let sdk = PublicReadSdk(noPointer: .init())
                sdk.lockedRead = {
                    if await recorder.events.isEmpty {
                        await recorder.record("active")
                        started.fulfill()
                        for await _ in gate {}
                    } else {
                        await recorder.record("ordered")
                    }
                }
                sdk.intake = { await recorder.record("intake") }
                sdk.publication = { capabilities in
                    XCTAssertFalse(capabilities.privatePayments)
                    await recorder.record("publish")
                }
                let service = PaykitSdkService(sdkFactory: { sdk })
                let active = Task { _ = try await service.contactRecords() }
                await fulfillment(of: [started], timeout: 2)

                let intake = Task { try await operation(service) }
                try await Task.sleep(for: .milliseconds(50))
                let barrier = testCase.orderedBarrier ? Task { _ = try await service.contactRecords() } : nil
                if barrier != nil { try await Task.sleep(for: .milliseconds(50)) }
                let publication = Task {
                    if let priority = testCase.priority {
                        try await service.syncPaykitApp(privatePaymentsEnabled: false, priority: priority)
                    } else {
                        try await service.syncPaykitApp(privatePaymentsEnabled: false)
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
                let heldEvents = await recorder.events
                XCTAssertEqual(heldEvents, ["active"])

                release.finish()
                try await active.value
                try await intake.value
                try await barrier?.value
                try await publication.value
                let events = await recorder.events
                XCTAssertEqual(events, testCase.expected)
            }
        }
    }

    func testPaymentMutationsOvertakeBackgroundWorkWithoutCrossingOrderedWork() async throws {
        for accepting in [false, true] {
            for orderedBarrier in [false, true] {
                let recorder = Recorder()
                let (gate, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                let started = expectation(description: "Active SDK operation started")
                let sdk = PublicReadSdk(noPointer: .init())
                sdk.lockedRead = {
                    if await recorder.events.isEmpty {
                        await recorder.record("active")
                        started.fulfill()
                        for await _ in gate {}
                    } else {
                        await recorder.record("ordered")
                    }
                }
                sdk.intake = { await recorder.record("intake") }
                sdk.paymentMutation = { operation in
                    XCTAssertEqual(operation, accepting ? "claimAndAccept" : "claim")
                    await recorder.record("payment")
                }
                let service = PaykitSdkService(sdkFactory: { sdk })
                let active = Task { _ = try await service.contactRecords() }
                await fulfillment(of: [started], timeout: 2)
                let intake = Task { _ = try await service.receivePrivateMessagesFromLinkedPeers(priority: .background) }
                try await Task.sleep(for: .milliseconds(50))
                let barrier = orderedBarrier ? Task { _ = try await service.contactRecords() } : nil
                if barrier != nil { try await Task.sleep(for: .milliseconds(50)) }
                let payment = Task {
                    do {
                        if accepting {
                            _ = try await service.acceptPaymentRequest(counterparty: "peer", paymentRequestId: "request")
                        } else {
                            _ = try await service.claimPaymentRequestForExecution(counterparty: "peer", paymentRequestId: "request")
                        }
                        XCTFail("Expected the SDK test operation to throw")
                    } catch PaymentMutationReached.reached {}
                }
                try await Task.sleep(for: .milliseconds(50))
                release.finish()
                try await active.value
                try await intake.value
                try await barrier?.value
                try await payment.value
                let events = await recorder.events
                XCTAssertEqual(events, orderedBarrier ? ["active", "intake", "ordered", "payment"] : ["active", "payment", "intake"])
            }
        }
    }

    @MainActor
    func testBackgroundOutboundDeliveryWaitsWhenPaymentStartsBeforeSending() async throws {
        for waitingInQueue in [true, false] {
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            let started = expectation(description: "SDK work before outbound delivery started")
            let recorder = Recorder()
            let pause: () async -> Void = {
                guard await recorder.events.isEmpty else { return }
                await recorder.record("waiting")
                started.fulfill()
                for await _ in gate {}
            }
            let sdk = PublicReadSdk(noPointer: .init())
            if waitingInQueue {
                sdk.lockedRead = pause
            } else {
                sdk.backupRevisionRead = pause
            }
            sdk.outboundDelivery = { await recorder.record("delivery") }
            let service = PaykitSdkService(sdkFactory: { sdk })
            let holder = waitingInQueue ? Task { try await service.contactRecords() } : nil
            if waitingInQueue { await fulfillment(of: [started], timeout: 2) }
            let delivery = Task { try await service.processOutboundPrivateMessages(counterparty: "peer", priority: .background) }
            defer { delivery.cancel() }
            if waitingInQueue {
                try await Task.sleep(for: .milliseconds(50))
            } else {
                await fulfillment(of: [started], timeout: 2)
            }
            let payment = PaykitPaymentActivity.shared.begin()
            defer { PaykitPaymentActivity.shared.end(payment) }
            release.finish()
            _ = try await holder?.value
            // The ordered read must still complete while outbound delivery waits for payment to finish.
            _ = try await service.identityStatus()
            let heldEvents = await recorder.events
            XCTAssertEqual(heldEvents, ["waiting"])
            PaykitPaymentActivity.shared.end(payment)
            _ = try await delivery.value
            let events = await recorder.events
            XCTAssertEqual(events, ["waiting", "delivery"])
        }
    }

    @MainActor
    func testDeferredOutboundDeliveryRejectsCancellationOrReplacedWallet() async throws {
        for change in ["cancel", "reset", "wipe"] {
            let recorder = Recorder()
            let service = PaykitSdkService(sdkFactory: {
                let sdk = PublicReadSdk(noPointer: .init())
                sdk.outboundDelivery = { await recorder.record("delivery") }
                return sdk
            })
            let payment = PaykitPaymentActivity.shared.begin()
            defer { PaykitPaymentActivity.shared.end(payment) }
            let delivery = Task { try await service.processOutboundPrivateMessages(counterparty: "peer", priority: .background) }
            defer { delivery.cancel() }
            try await Task.sleep(for: .milliseconds(50))
            switch change {
            case "cancel": delivery.cancel()
            case "reset": await service.clearState()
            default: try await service.withWalletWipe {}
            }
            PaykitPaymentActivity.shared.end(payment)
            do {
                _ = try await delivery.value
                XCTFail("Deferred outbound delivery must not survive \(change)")
            } catch is CancellationError {
                XCTAssertEqual(change, "cancel")
            } catch PubkyServiceError.identityChanged {
                XCTAssertNotEqual(change, "cancel")
            }
            let events = await recorder.events
            XCTAssertTrue(events.isEmpty)
        }
    }

    @MainActor
    func testForegroundOutboundDeliveryDoesNotWaitForPaymentToFinish() async throws {
        let payment = PaykitPaymentActivity.shared.begin()
        defer { PaykitPaymentActivity.shared.end(payment) }
        let recorder = Recorder()
        let sdk = PublicReadSdk(noPointer: .init())
        sdk.outboundDelivery = { await recorder.record("delivery") }
        let service = PaykitSdkService(sdkFactory: { sdk })
        for priority in [PaykitSdkOperationLock.Priority.ordered, .interactive] {
            _ = try await service.processOutboundPrivateMessages(counterparty: "peer", priority: priority)
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["delivery", "delivery"])
    }

    @MainActor
    func testBackupExportWaitsForPaymentEvenWhenPaymentStartsWhileExportIsQueued() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let started = expectation(description: "Active SDK operation started")
        let sdk = PublicReadSdk(noPointer: .init())
        sdk.lockedRead = {
            started.fulfill()
            for await _ in gate {}
        }
        let recorder = Recorder()
        sdk.backupExport = { await recorder.record("export") }
        let service = PaykitSdkService(sdkFactory: { sdk })
        let holder = Task { try await service.contactRecords() }
        await fulfillment(of: [started], timeout: 2)
        let export = Task { try await service.exportBackupState() }
        try await Task.sleep(for: .milliseconds(50))
        let payment = PaykitPaymentActivity.shared.begin()
        defer { PaykitPaymentActivity.shared.end(payment) }
        release.finish()
        _ = try await holder.value
        // An ordered read completing proves the deferred export does not hold the SDK lock.
        _ = try await service.identityStatus()
        let heldEvents = await recorder.events
        XCTAssertTrue(heldEvents.isEmpty)
        PaykitPaymentActivity.shared.end(payment)
        let backup = try await export.value
        XCTAssertEqual(backup, "backup")
        let events = await recorder.events
        XCTAssertEqual(events, ["export"])
    }

    @MainActor
    func testDeferredBackupRejectsCancellationOrReplacedWallet() async throws {
        for change in ["cancel", "reset", "wipe"] {
            let recorder = Recorder()
            let service = PaykitSdkService(sdkFactory: {
                let sdk = PublicReadSdk(noPointer: .init())
                sdk.backupExport = { await recorder.record("export") }
                return sdk
            })
            let payment = PaykitPaymentActivity.shared.begin()
            defer { PaykitPaymentActivity.shared.end(payment) }
            let export = Task { try await service.exportBackupState() }
            try await Task.sleep(for: .milliseconds(50))
            switch change {
            case "cancel": export.cancel()
            case "reset": await service.clearState()
            default: try await service.withWalletWipe {}
            }
            PaykitPaymentActivity.shared.end(payment)
            do {
                _ = try await export.value
                XCTFail("Deferred backup must not survive \(change)")
            } catch is CancellationError {
                XCTAssertEqual(change, "cancel")
            } catch PubkyServiceError.identityChanged {
                XCTAssertNotEqual(change, "cancel")
            }
            let events = await recorder.events
            XCTAssertTrue(events.isEmpty)
        }
    }

    private func assertQueuedOrder(
        priorities: [PaykitSdkOperationLock.Priority],
        expected: [Int],
        cancelIndex: Int? = nil
    ) async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let started = expectation(description: "Active publication started")
        let active = Task {
            try await lock.withLock(priority: .background) {
                await recorder.record("active")
                started.fulfill()
                for await _ in gate {}
            }
        }
        await fulfillment(of: [started], timeout: 2)

        var queued: [Task<Void, Error>] = []
        for (index, priority) in priorities.enumerated() {
            queued.append(Task {
                try await lock.withLock(priority: priority) { await recorder.record(String(index)) }
            })
            await waitForWaiters(lock, count: index + 1)
        }
        let heldEvents = await recorder.events
        XCTAssertEqual(heldEvents, ["active"], "Active publication must not be preempted")
        if let cancelIndex { queued[cancelIndex].cancel() }
        release.finish()
        try await active.value
        for (index, task) in queued.enumerated() {
            if index == cancelIndex {
                do {
                    try await task.value
                    XCTFail("Expected cancellation")
                } catch is CancellationError {}
            } else {
                try await task.value
            }
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["active"] + expected.map(String.init))
        try await lock.withLock {}
    }

    private func waitForWaiters(_ lock: PaykitSdkOperationLock, count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lock.waiterCountForTesting < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(lock.waiterCountForTesting, count)
    }

    func testPublicCapabilityReadDoesNotWaitForSerializedSdkWork() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let started = expectation(description: "Serialized work started")
        let read = expectation(description: "Public capability read completes while serialized work is suspended")
        let sdk = PublicReadSdk(noPointer: .init())
        sdk.lockedRead = {
            started.fulfill()
            for await _ in gate {}
        }
        let service = PaykitSdkService(sdkFactory: { sdk })
        let holder = Task { try await service.contactRecords() }
        await fulfillment(of: [started], timeout: 2)

        let lookup = Task {
            let result = try await service.canReceivePaymentRequests(publicKey: "peer")
            XCTAssertFalse(result)
            let resolution = try await service.resolvePublicContactPayment(counterparty: "peer")
            XCTAssertEqual(resolution.status, .noEndpoint)
            read.fulfill()
        }
        await fulfillment(of: [read], timeout: 0.5)
        release.finish()
        _ = try await holder.value
        try await lookup.value
    }

    func testPublicPaymentResolutionDiscardsReplacedRuntimeAndAllowsFreshRead() async throws {
        for wipe in [false, true] {
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            let started = expectation(description: "Public payment resolution started")
            let sdk = PublicReadSdk(noPointer: .init())
            sdk.publicRead = {
                started.fulfill()
                for await _ in gate {}
            }
            let service = PaykitSdkService(sdkFactory: { sdk })
            let lookup = Task { try await service.resolvePublicContactPayment(counterparty: "peer") }
            await fulfillment(of: [started], timeout: 2)
            if wipe {
                try await service.withWalletWipe {}
            } else {
                await service.clearState()
            }
            release.finish()
            do {
                _ = try await lookup.value
                XCTFail("Expected replaced runtime result to be rejected")
            } catch PubkyServiceError.identityChanged {}
            sdk.publicRead = {}
            let fresh = try await service.resolvePublicContactPayment(counterparty: "peer")
            XCTAssertEqual(fresh.status, .noEndpoint)
        }
    }

    func testPublicReadDiscardsCancelledResult() async throws {
        let lock = PaykitSdkOperationLock()
        let lookup = Task {
            try await lock.withoutLock {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        do {
            _ = try await lookup.value
            XCTFail("Expected cancelled result to be rejected")
        } catch is CancellationError {}
        try await lock.withLock {}
    }

    func testAlreadyCancelledPublicReadDoesNotStart() async throws {
        let lock = PaykitSdkOperationLock()
        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await lock.withoutLock { XCTFail("Cancelled public read must not start") }
        }
        do {
            try await lookup.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testWipeDrainsActiveWorkRejectsQueuedWorkAndAllowsCleanupAndFreshWork() async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let (wipeGate, releaseWipe) = AsyncStream<Void>.makeStream()
        let (wipeStarted, startWipe) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                await recorder.record("active")
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        var queued: [Task<Void, Error>] = []
        for priority in [PaykitSdkOperationLock.Priority.background, .interactive] {
            queued.append(Task {
                try await lock.withLock(priority: priority) { await recorder.record("stale") }
            })
            await waitForWaiters(lock, count: queued.count)
        }
        let wipe = Task {
            try await lock.withWalletWipe {
                try await lock.withLock { await recorder.record("cleanup") }
                startWipe.yield()
                for await _ in wipeGate {
                    break
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        do {
            try await lock.withLock { await recorder.record("poll") }
            XCTFail("Expected work during wipe to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        releaseActive.yield()
        for await _ in wipeStarted {
            break
        }
        for task in queued {
            do {
                try await task.value
                XCTFail("Expected queued work from the old wallet to be rejected")
            } catch let PaykitError.Storage(code, _) {
                XCTAssertEqual(code, "wallet_wipe_in_progress")
            }
        }
        releaseWipe.yield()
        try await active.value
        try await wipe.value
        try await lock.withLock { await recorder.record("fresh") }
        let events = await recorder.events
        XCTAssertEqual(events, ["active", "cleanup", "fresh"])
    }

    func testUnlockedWorkSkipsTheLockButNotWipeAdmission() async throws {
        let lock = PaykitSdkOperationLock()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        let unlocked = try await lock.withoutLock { "unlocked" }
        XCTAssertEqual(unlocked, "unlocked", "Unlocked work must not wait for the lock")

        let (overtakenGate, releaseOvertaken) = AsyncStream<Void>.makeStream()
        let (overtakenStarted, startOvertaken) = AsyncStream<Void>.makeStream()
        let overtaken = Task {
            try await lock.withoutLock {
                startOvertaken.yield()
                for await _ in overtakenGate {
                    break
                }
                return "stale"
            }
        }
        for await _ in overtakenStarted {
            break
        }
        let (wipeGate, releaseWipe) = AsyncStream<Void>.makeStream()
        let wipe = Task {
            try await lock.withWalletWipe {
                let owner = try await lock.withoutLock { "owner" }
                XCTAssertEqual(owner, "owner", "The wipe's own unlocked work must still run")
                for await _ in wipeGate {
                    break
                }
            }
        }
        try await waitUntilWiping(lock)

        do {
            try await lock.withoutLock { XCTFail("Unlocked work ran during a wipe") }
            XCTFail("Expected unlocked work during a wipe to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        releaseOvertaken.yield()
        do {
            _ = try await overtaken.value
            XCTFail("Expected unlocked work that a wipe overtook to fail instead of returning its result")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }

        releaseActive.yield()
        releaseWipe.yield()
        try await active.value
        try await wipe.value
        let fresh = try await lock.withoutLock { "fresh" }
        XCTAssertEqual(fresh, "fresh")
    }

    func testCancelledWipeDrainsActiveWorkWithoutRunningCleanup() async throws {
        let lock = PaykitSdkOperationLock()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        let wipe = Task {
            try await lock.withWalletWipe { XCTFail("Cancelled wipe ran cleanup") }
        }
        try await Task.sleep(for: .milliseconds(50))
        wipe.cancel()
        releaseActive.yield()
        try await active.value
        do {
            try await wipe.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        try await lock.withLock {}
    }

    func testFailedWipeReleasesAdmission() async throws {
        let lock = PaykitSdkOperationLock()
        do {
            try await lock.withWalletWipe { throw KeychainError.failedToDelete }
            XCTFail("Expected cleanup failure")
        } catch KeychainError.failedToDelete {}
        try await lock.withLock {}
    }

    private func waitUntilWiping(_ lock: PaykitSdkOperationLock) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (try? lock.walletGeneration()) != nil {
            guard ContinuousClock.now < deadline else {
                return XCTFail("The wipe never started")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum PaymentMutationReached: Error {
    case reached
}

private final class PublicReadSdk: PaykitSdk, @unchecked Sendable {
    var lockedRead: () async -> Void = {}
    var publicRead: () async -> Void = {}
    var intake: () async -> Void = {}
    var publication: (PaykitAppCapabilities) async -> Void = { _ in }
    var paymentMutation: (String) async -> Void = { _ in }
    var backupExport: () async -> Void = {}
    var outboundDelivery: () async -> Void = {}
    var backupRevisionRead: () async -> Void = {}

    override func processOutboundPrivateMessages(counterparty _: String) async throws -> OutboundPrivateSendReport {
        await outboundDelivery()
        return OutboundPrivateSendReport(attempted: [], sent: [], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: [])
    }

    override func claimPaymentRequestForExecution(counterparty _: String, paymentRequestId _: String) async throws -> PaymentRequestRecord {
        await paymentMutation("claim")
        throw PaymentMutationReached.reached
    }

    override func claimAndAcceptPaymentRequest(counterparty _: String, paymentRequestId _: String) async throws -> PaymentRequestRecord {
        await paymentMutation("claimAndAccept")
        throw PaymentMutationReached.reached
    }

    override func exportBackupString() async throws -> String {
        await backupExport()
        return "backup"
    }

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: nil, capability: .privateLinkCapable)
    }

    override func stateRevision() throws -> String? {
        "state"
    }

    override func backupStateRevision() async throws -> String {
        await backupRevisionRead()
        return "revision"
    }

    override func observedBackupStateRevision() throws -> ObservedBackupStateRevision? {
        nil
    }

    override func receivePrivateMessagesFromLinkedPeers() async throws -> [PrivateStreamCounterpartyIntakeReport] {
        await intake()
        return []
    }

    override func ensureLinkWithPeer(counterparty: String, maxAdvanceSteps: UInt32) async throws -> LinkedPeerHandshakeReport {
        XCTAssertEqual(maxAdvanceSteps, 1)
        await intake()
        return LinkedPeerHandshakeReport(counterparty: counterparty, state: .linking, generation: 1, handshakeRole: nil)
    }

    override func publishPaykitApp(displayName _: String, capabilities: PaykitAppCapabilities) async throws -> PaykitAppRegistry {
        await publication(capabilities)
        return PaykitAppRegistry(keyGeneration: 1, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
    }

    override func resolvePublicContactPayment(counterparty _: String,
                                              amount _: PaymentAmountContext?) async throws -> PublicContactPaymentResolution
    {
        await publicRead()
        return PublicContactPaymentResolution(status: .noEndpoint, payableEndpoints: [], failures: [])
    }

    override func paykitAppRegistry(publicKey _: String) async throws -> PaykitAppRegistry? {
        return nil
    }

    override func contactRecords() async throws -> [ContactRecord] {
        await lockedRead()
        return []
    }
}
