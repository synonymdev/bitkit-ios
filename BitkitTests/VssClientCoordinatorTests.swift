@testable import Bitkit
import XCTest

final class VssClientCoordinatorTests: XCTestCase {
    func testResetDrainsOldSetupAndRejectsLateCompletion() async throws {
        let coordinator = VssClientCoordinator()
        let gate = Gate()
        let started = expectation(description: "Original setup started")
        let cancelled = expectation(description: "Reset cancelled original setup")
        let retired = expectation(description: "Retirement must await old setup")
        let shutdowns = Counter()
        let old = Task {
            try await coordinator.withClient(domain: .app, setup: {
                await withTaskCancellationHandler {
                    started.fulfill()
                    await gate.wait()
                } onCancel: { cancelled.fulfill() }
            }, operation: { XCTFail("Retired setup must not dispatch a call") })
        }
        await fulfillment(of: [started], timeout: 2)
        let reset = Task { await coordinator.reset { shutdowns.increment(); retired.fulfill() } }
        await fulfillment(of: [cancelled], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(shutdowns.value, 0)
        do {
            try await coordinator.withClient(domain: .ldk, setup: { XCTFail("Admission during drain") }, operation: {})
            XCTFail("Admission during reset must fail")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await gate.release()
        await assertCancelled(old)
        await reset.value
        await fulfillment(of: [retired], timeout: 2)
        let replacement = expectation(description: "Replacement setup runs")
        try await coordinator.withClient(domain: .app, setup: { replacement.fulfill() }, operation: {})
        await fulfillment(of: [replacement], timeout: 2)
    }

    func testResetDrainsBothDomainsAndRejectsTheirResults() async throws {
        let coordinator = VssClientCoordinator()
        let appGate = Gate()
        let ldkGate = Gate()
        let started = expectation(description: "Both calls admitted")
        started.expectedFulfillmentCount = 2
        let retired = expectation(description: "Both calls must drain before shutdown")
        let shutdowns = Counter()
        let app = Task {
            try await coordinator.withClient(domain: .app, setup: {}, operation: {
                started.fulfill()
                await appGate.wait()
            })
        }
        let ldk = Task {
            try await coordinator.withClient(domain: .ldk, setup: {}, operation: {
                started.fulfill()
                await ldkGate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        let reset = Task { await coordinator.reset { shutdowns.increment(); retired.fulfill() } }
        await waitForClosedAdmission(coordinator)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(shutdowns.value, 0)
        await appGate.release()
        await assertCancelled(app)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(shutdowns.value, 0)
        await ldkGate.release()
        await assertCancelled(ldk)
        await reset.value
        await fulfillment(of: [retired], timeout: 2)
    }

    func testCancelledResetStillWaitsForNativeCall() async throws {
        let coordinator = VssClientCoordinator()
        let gate = Gate()
        let started = expectation(description: "Call admitted")
        let retired = expectation(description: "Native retirement")
        let shutdowns = Counter()
        let old = Task {
            try await coordinator.withClient(domain: .app, setup: {}, operation: {
                started.fulfill()
                await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        let reset = Task { await coordinator.reset { shutdowns.increment(); retired.fulfill() } }
        await waitForClosedAdmission(coordinator)
        reset.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(shutdowns.value, 0)
        await gate.release()
        await assertCancelled(old)
        await reset.value
        await fulfillment(of: [retired], timeout: 2)
        XCTAssertEqual(shutdowns.value, 1)
        try await coordinator.withClient(domain: .app, setup: {}, operation: {})
    }

    func testAdmissionStaysClosedThroughoutCredentialRemovalAndReopensAfterFailure() async throws {
        let coordinator = VssClientCoordinator()
        try await coordinator.withClient(domain: .app, setup: {}, operation: {})
        do {
            try await coordinator.withSuspendedClients(shutdown: {}, operation: {
                for domain in [VssClientCoordinator.Domain.app, .ldk] {
                    do {
                        try await coordinator.withClient(domain: domain, setup: {
                            XCTFail("Old credentials must not be read")
                        }, operation: {})
                        XCTFail("Wallet transition must keep admission closed")
                    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
                }
                throw URLError(.cannotWriteToFile)
            })
            XCTFail("Transition failure must propagate")
        } catch let error as URLError { XCTAssertEqual(error.code, .cannotWriteToFile) }
        let setup = expectation(description: "Failure still retires cached setup")
        try await coordinator.withClient(domain: .app, setup: { setup.fulfill() }, operation: {})
        await fulfillment(of: [setup], timeout: 2)
    }

    @MainActor
    func testWipeDrainsAfterNodeStopAndKeepsAdmissionClosedThroughCommit() async throws {
        for (holdSetup, resetBeforeWipe) in [(true, false), (false, false), (false, true)] {
            let clients = VssClientCoordinator()
            let oldGate = Gate()
            let tailGate = Gate()
            let started = expectation(description: "Original VSS work admitted")
            let prefixFinished = expectation(description: "Node stop and remote cleanup finished")
            let credentialsRemoved = expectation(description: "Credential deletion reached")
            let store = FakePinLockoutStore()
            store.pin = "1234"
            let recording = RecordingWipeExecutor(device: FakeWipedDevice(store: store))
            let executor = VssWipeExecutor(recording: recording, clients: clients)
            executor.onStep = { step in
                if step == .removeRemoteEndpoints {
                    prefixFinished.fulfill()
                }
                if step == .wipeKeychain || step == .commit {
                    await self.assertClosed(clients)
                }
                if step == .wipeKeychain {
                    credentialsRemoved.fulfill()
                    await tailGate.wait()
                }
            }
            let old = Task {
                try await clients.withClient(domain: .app, setup: {
                    if holdSetup {
                        started.fulfill()
                        await oldGate.wait()
                    }
                }, operation: {
                    if holdSetup {
                        XCTFail("Retired setup must not dispatch")
                    } else {
                        started.fulfill()
                        await oldGate.wait()
                    }
                })
            }
            await fulfillment(of: [started], timeout: 2)
            let reset: Task<Void, Never>?
            if resetBeforeWipe {
                reset = Task { await clients.reset {} }
                await waitForClosedAdmission(clients, domain: .ldk)
            } else {
                reset = nil
            }
            let wipe = WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [])
            try wipe.begin(.userReset)
            await fulfillment(of: [prefixFinished], timeout: 2)
            guard await waitForClosedAdmission(clients, domain: .ldk) else {
                await oldGate.release()
                await tailGate.release()
                _ = await old.result
                await wipe.waitForCurrentAttempt()
                continue
            }

            XCTAssertEqual(recording.ranSteps, [.quiesce, .stopNode, .removeRemoteEndpoints])
            XCTAssertEqual(executor.shutdowns.value, 0)
            XCTAssertEqual(store.pin, "1234")
            await assertClosed(clients)
            await oldGate.release()
            await assertCancelled(old)
            await reset?.value
            await fulfillment(of: [credentialsRemoved], timeout: 2)

            XCTAssertEqual(executor.shutdowns.value, 1)
            XCTAssertEqual(recording.ranSteps.last, .wipeKeychain)
            XCTAssertEqual(store.pin, "1234")
            XCTAssertNotNil(store.intent)
            XCTAssertTrue(recording.finishedReasons.isEmpty)
            await assertClosed(clients)
            await tailGate.release()
            await wipe.waitForCurrentAttempt()

            XCTAssertEqual(recording.ranSteps, WipeStep.allCases)
            XCTAssertEqual(recording.finishedReasons, [.userReset])
            XCTAssertEqual(wipe.gate, .none)
            XCTAssertEqual(executor.shutdowns.value, 1)
            let freshSetups = Counter()
            for domain in [VssClientCoordinator.Domain.app, .ldk] {
                try await clients.withClient(domain: domain, setup: { freshSetups.increment() }, operation: {})
            }
            XCTAssertEqual(freshSetups.value, 2)
        }
    }

    func testRetiredNativeFailureIsCancellationRatherThanNewOwnerAuthFailure() async {
        let coordinator = VssClientCoordinator()
        let gate = Gate()
        let started = expectation(description: "Old call admitted")
        let old = Task {
            try await coordinator.withClient(domain: .app, setup: {}, operation: {
                started.fulfill()
                await gate.wait()
                throw URLError(.userAuthenticationRequired)
            })
        }
        await fulfillment(of: [started], timeout: 2)
        let reset = Task { await coordinator.reset {} }
        await waitForClosedAdmission(coordinator)
        await gate.release()
        await assertCancelled(old)
        await reset.value
    }

    func testConcurrentCallsShareSetupAndRemainConcurrent() async throws {
        let coordinator = VssClientCoordinator()
        let setupGate = Gate()
        let callGate = Gate()
        let setupStarted = expectation(description: "One setup")
        setupStarted.assertForOverFulfill = true
        let callsStarted = expectation(description: "Both calls run concurrently")
        callsStarted.expectedFulfillmentCount = 2
        let setup = { setupStarted.fulfill(); await setupGate.wait() }
        let operation = { callsStarted.fulfill(); await callGate.wait() }
        let first = Task { try await coordinator.withClient(domain: .app, setup: setup, operation: operation) }
        await fulfillment(of: [setupStarted], timeout: 2)
        let second = Task { try await coordinator.withClient(domain: .app, setup: setup, operation: operation) }
        await setupGate.release()
        await fulfillment(of: [callsStarted], timeout: 2)
        await callGate.release()
        try await first.value
        try await second.value
    }

    func testFailedSetupCanRetryWithoutAdmittingItsOperation() async throws {
        let coordinator = VssClientCoordinator()
        do {
            try await coordinator.withClient(domain: .app, setup: { throw URLError(.notConnectedToInternet) }, operation: {
                XCTFail("Failed setup must not dispatch")
            })
            XCTFail("Setup must fail")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        let value = try await coordinator.withClient(domain: .app, setup: {}, operation: { 42 })
        XCTAssertEqual(value, 42)
    }

    func testCancelledWaiterDoesNotInvalidateSuccessfulSharedSetup() async throws {
        let coordinator = VssClientCoordinator()
        let gate = Gate()
        let started = expectation(description: "Setup started")
        let first = Task {
            try await coordinator.withClient(domain: .app, setup: {
                started.fulfill()
                await gate.wait()
            }, operation: { XCTFail("Cancelled caller must not dispatch") })
        }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        await gate.release()
        await assertCancelled(first)
        try await coordinator.withClient(domain: .app, setup: { XCTFail("Setup already succeeded") }, operation: {})
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await task.value
            XCTFail("Retired call must fail", file: file, line: line)
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    @discardableResult
    private func waitForClosedAdmission(_ coordinator: VssClientCoordinator, domain: VssClientCoordinator.Domain = .app) async -> Bool {
        for _ in 0 ..< 100 {
            do { try await coordinator.withClient(domain: domain, setup: {}, operation: {}) }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected error: \(error)"); return false }
            await Task.yield()
        }
        XCTFail("Reset did not close admission")
        return false
    }

    private func assertClosed(_ coordinator: VssClientCoordinator) async {
        for domain in [VssClientCoordinator.Domain.app, .ldk] {
            do {
                try await coordinator.withClient(domain: domain, setup: {
                    XCTFail("Credentials must not be read during the wipe")
                }, operation: { XCTFail("Native work must not start during the wipe") })
                XCTFail("Admission must stay closed through commit")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    private final class VssWipeExecutor: WipeStepExecutor {
        let recording: RecordingWipeExecutor
        let clients: VssClientCoordinator
        let shutdowns = Counter()
        var onStep: ((WipeStep) async -> Void)?

        init(recording: RecordingWipeExecutor, clients: VssClientCoordinator) {
            self.recording = recording
            self.clients = clients
        }

        func withWipeScope(permitsRemoteCleanup: Bool, _ steps: () async throws -> Void) async throws {
            try await recording.withWipeScope(permitsRemoteCleanup: permitsRemoteCleanup, steps)
        }

        func withLocalStateWipeScope(_ steps: () async throws -> Void) async throws {
            let shutdowns = shutdowns
            try await clients.withSuspendedClients(shutdown: { shutdowns.increment() }, operation: steps)
        }

        func run(_ step: WipeStep) async throws {
            try await recording.run(step)
            await onStep?(step)
        }

        func finish(reason: WipeReason?) {
            recording.finish(reason: reason)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    /// Deliberately ignores cancellation, like a native FFI call already in progress.
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}
