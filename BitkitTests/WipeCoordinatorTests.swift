@testable import Bitkit
import Combine
import XCTest

@MainActor
final class WipeCoordinatorTests: XCTestCase {
    private var store: FakePinLockoutStore!
    private var device: FakeWipedDevice!

    override func setUp() {
        super.setUp()
        resetFixtures()
    }

    private func resetFixtures() {
        store = FakePinLockoutStore()
        store.pin = "1234"
        device = FakeWipedDevice(store: store)
    }

    private func makeCoordinator(_ executor: RecordingWipeExecutor?) -> WipeCoordinator {
        WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [])
    }

    // MARK: - Resuming after a kill

    func testWipeKilledAfterAnyStepResumesAtLaunchAndDeletesInOrder() async {
        for killedStep in WipeStep.allCases where killedStep != .commit {
            resetFixtures()
            let firstRun = RecordingWipeExecutor(device: device)
            firstRun.killedAfter = killedStep
            let killed = makeCoordinator(firstRun)
            try? killed.begin(.userReset)
            await killed.waitForCurrentAttempt()
            XCTAssertNotNil(store.intent, "\(killedStep)")

            let relaunch = RecordingWipeExecutor(device: device)
            let relaunched = makeCoordinator(relaunch)
            let launchesNormally = await relaunched.prepareForLaunch()

            XCTAssertFalse(launchesNormally, "\(killedStep)")
            XCTAssertEqual(relaunch.ranSteps, WipeStep.allCases, "A resumed wipe runs every step again: \(killedStep)")
            XCTAssertNil(store.intent, "\(killedStep)")
            XCTAssertNil(store.pin, "\(killedStep)")
            XCTAssertEqual(relaunched.gate, .none, "\(killedStep)")
            XCTAssertEqual(relaunch.finishedReasons, [.userReset], "\(killedStep)")
            XCTAssertTrue(device.lockoutHeldUntilItsStep, "\(killedStep)")
            XCTAssertEqual(Array(device.deletions.suffix(4)), ["mnemonic", "settings", "pin", "intent"], "\(killedStep)")
        }
    }

    func testRelaunchAfterTheCommitLaunchesNormally() async {
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)
        try? coordinator.begin(.userReset)
        await coordinator.waitForCurrentAttempt()

        let relaunch = RecordingWipeExecutor(device: device)
        let launchesNormally = await makeCoordinator(relaunch).prepareForLaunch()

        XCTAssertTrue(launchesNormally)
        XCTAssertTrue(relaunch.ranSteps.isEmpty)
    }

    // MARK: - Failures

    func testNodeStopFailureRunsNoLaterStepKeepsTheIntentAndRetries() async {
        let executor = RecordingWipeExecutor(device: device)
        executor.failingSteps = [.stopNode]
        let coordinator = makeCoordinator(executor)

        try? coordinator.begin(.userReset)
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(executor.ranSteps, [.quiesce])
        XCTAssertEqual(executor.localScopeEntries, 0)
        XCTAssertEqual(coordinator.progress, .failed(.stopNode))
        XCTAssertEqual(coordinator.gate, .wiping)
        XCTAssertEqual(store.intentReason, .userReset)
        XCTAssertTrue(executor.finishedReasons.isEmpty)

        executor.failingSteps = []
        coordinator.retry()
        await coordinator.waitForCurrentAttempt()

        XCTAssertNil(store.intent)
        XCTAssertEqual(coordinator.gate, .none)
        XCTAssertEqual(executor.finishedReasons, [.userReset])
    }

    func testLocalWipeFailureKeepsTheGateAndRetriesUnderAFreshScope() async {
        for failsEnteringScope in [true, false] {
            resetFixtures()
            let executor = RecordingWipeExecutor(device: device)
            executor.failsEnteringLocalScope = failsEnteringScope
            executor.failingSteps = failsEnteringScope ? [] : [.wipeKeychain]
            let coordinator = makeCoordinator(executor)

            try? coordinator.begin(.userReset)
            await coordinator.waitForCurrentAttempt()

            XCTAssertFalse(executor.ranSteps.contains(.resetSettings))
            XCTAssertFalse(executor.ranSteps.contains(.deletePin))
            XCTAssertEqual(store.pin, "1234")
            XCTAssertNotNil(store.intent)
            XCTAssertEqual(coordinator.gate, .wiping)
            XCTAssertEqual(coordinator.progress, .failed(failsEnteringScope ? .resetLocalServices : .wipeKeychain))
            XCTAssertEqual(executor.localScopeEntries, 1)
            XCTAssertEqual(executor.localScopeExits, 1)
            XCTAssertTrue(executor.finishedReasons.isEmpty)
            if failsEnteringScope {
                XCTAssertEqual(executor.ranSteps, [.quiesce, .stopNode, .removeRemoteEndpoints])
            }

            executor.failsEnteringLocalScope = false
            executor.failingSteps = []
            coordinator.retry()
            await coordinator.waitForCurrentAttempt()

            XCTAssertEqual(Array(executor.ranSteps.suffix(WipeStep.allCases.count)), WipeStep.allCases)
            XCTAssertEqual(executor.localScopeEntries, 2)
            XCTAssertEqual(executor.localScopeExits, 2)
            XCTAssertEqual(executor.finishedReasons, [.userReset])
            XCTAssertEqual(device.deletions, ["mnemonic", "settings", "pin", "intent"])
            XCTAssertNil(store.intent)
            XCTAssertNil(store.pin)
            XCTAssertEqual(coordinator.gate, .none)
        }
    }

    func testFailedStepIsRetriedAutomatically() async throws {
        let executor = RecordingWipeExecutor(device: device)
        executor.failingSteps = [.wipeDatabases]
        let coordinator = WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [.milliseconds(10)])

        try coordinator.begin(.userReset)
        await coordinator.waitForCurrentAttempt()
        XCTAssertEqual(coordinator.progress, .failed(.wipeDatabases))

        executor.failingSteps = []
        for _ in 0 ..< 200 where coordinator.gate != .none {
            try await Task.sleep(for: .milliseconds(10))
            await coordinator.waitForCurrentAttempt()
        }

        XCTAssertEqual(coordinator.gate, .none)
        XCTAssertNil(store.intent)
    }

    // MARK: - Starting

    func testEveryReasonConfirmsTheIntentBeforeTheFirstStep() async {
        for reason in [WipeReason.userReset, .forgotPin, .recoveryReset, .dev] {
            resetFixtures()
            let executor = RecordingWipeExecutor(device: device)
            let coordinator = makeCoordinator(executor)

            try? coordinator.begin(reason)
            await coordinator.waitForCurrentAttempt()

            XCTAssertEqual(executor.intentReasonAtFirstStep, reason)
            XCTAssertEqual(executor.finishedReasons, [reason])
        }
    }

    func testSecondBeginJoinsTheRunningWipe() async throws {
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)

        try coordinator.begin(.userReset)
        try coordinator.begin(.dev)
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(executor.scopeEntries, 1)
        XCTAssertEqual(executor.finishedReasons, [.userReset])
    }

    func testResetWhoseIntentCannotBeWrittenDeletesNothing() async {
        for dropsWrite in [false, true] {
            resetFixtures()
            store.failsSavingIntent = !dropsWrite
            store.dropsSavedIntent = dropsWrite
            var madeExecutor = false
            let coordinator = WipeCoordinator(store: store, makeExecutor: {
                madeExecutor = true
                return nil
            }, retryDelays: [])

            XCTAssertThrowsError(try coordinator.begin(.userReset), "dropsWrite: \(dropsWrite)")
            await coordinator.waitForCurrentAttempt()

            XCTAssertFalse(madeExecutor, "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(coordinator.gate, .none, "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(store.pin, "1234", "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(store.failedAttempts, 0, "dropsWrite: \(dropsWrite)")
        }
    }

    // MARK: - Launch

    func testUnreadableIntentBlocksTheLaunchWithoutRunningAnyStep() async {
        store.failsLoadingIntent = true
        var madeExecutor = false
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = WipeCoordinator(store: store, makeExecutor: {
            madeExecutor = true
            return executor
        }, retryDelays: [])

        let launchesNormally = await coordinator.prepareForLaunch()

        XCTAssertFalse(launchesNormally)
        XCTAssertEqual(coordinator.gate, .blocked)
        XCTAssertFalse(madeExecutor)

        coordinator.retry()
        XCTAssertEqual(coordinator.gate, .blocked, "A read that still fails keeps access blocked")
        XCTAssertFalse(madeExecutor)

        store.failsLoadingIntent = false
        coordinator.retry()
        XCTAssertEqual(coordinator.gate, .none, "A read that finds no intent lifts the block")
        XCTAssertTrue(coordinator.didHoldLaunch, "The held launch starts over")
        XCTAssertFalse(madeExecutor)
    }

    func testBlockRaisedInARunningSessionLiftsWithoutRestartingTheLaunch() async {
        let coordinator = makeCoordinator(RecordingWipeExecutor(device: device))
        let launchesNormally = await coordinator.prepareForLaunch()
        XCTAssertTrue(launchesNormally)

        store.failsLoadingIntent = true
        coordinator.applyPersistedIntent()
        XCTAssertEqual(coordinator.gate, .blocked)

        store.failsLoadingIntent = false
        coordinator.retry()

        XCTAssertEqual(coordinator.gate, .none)
        XCTAssertFalse(coordinator.didHoldLaunch)
    }

    func testExhaustedCounterBehindAnUnreadableIntentAtLaunchIsWipedInsteadOfUnlocked() async {
        store.failedAttempts = Env.pinAttempts
        store.failsLoadingIntent = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)
        var gates: [WipeCoordinator.Gate] = []
        let observation = coordinator.$gate.sink { gates.append($0) }
        defer { observation.cancel() }

        let launchesNormally = await coordinator.prepareForLaunch()
        XCTAssertFalse(launchesNormally)
        XCTAssertEqual(coordinator.gate, .blocked)

        store.failsLoadingIntent = false
        coordinator.retry()
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(gates, [.none, .blocked, .wiping, .none], "The block lifts only once the wipe has completed")
        XCTAssertEqual(executor.intentReasonAtFirstStep, .pinAttemptsExceeded)
        XCTAssertEqual(executor.finishedReasons, [.pinAttemptsExceeded])
        XCTAssertNil(store.pin)
    }

    func testUnreadableIntentThatReadsAsPendingLaterResumes() async {
        store.intent = try? JSONEncoder().encode(WipeIntent(reason: .forgotPin, startedAt: 0))
        store.failsLoadingIntent = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)

        let launchesNormally = await coordinator.prepareForLaunch()
        XCTAssertFalse(launchesNormally)
        XCTAssertTrue(executor.ranSteps.isEmpty)

        store.failsLoadingIntent = false
        coordinator.retry()
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(executor.ranSteps, WipeStep.allCases)
        XCTAssertEqual(executor.finishedReasons, [.forgotPin])
    }

    func testUndecodableIntentStillResumes() async {
        store.intent = Data("not json".utf8)
        let executor = RecordingWipeExecutor(device: device)

        let launchesNormally = await makeCoordinator(executor).prepareForLaunch()

        XCTAssertFalse(launchesNormally)
        XCTAssertEqual(executor.ranSteps, WipeStep.allCases)
    }

    func testExhaustedCounterWithAPinIsPromotedToAWipeAtLaunch() async {
        store.failedAttempts = Env.pinAttempts
        let executor = RecordingWipeExecutor(device: device)

        let launchesNormally = await makeCoordinator(executor).prepareForLaunch()

        XCTAssertFalse(launchesNormally)
        XCTAssertEqual(executor.intentReasonAtFirstStep, .pinAttemptsExceeded)
        XCTAssertEqual(executor.finishedReasons, [.pinAttemptsExceeded])
    }

    func testPromotionWhoseIntentCannotBeWrittenLocksOutWithoutDeleting() async {
        store.failedAttempts = Env.pinAttempts
        store.failsSavingIntent = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)

        let launchesNormally = await coordinator.prepareForLaunch()

        XCTAssertFalse(launchesNormally)
        XCTAssertEqual(coordinator.gate, .wiping)
        XCTAssertEqual(coordinator.progress, .failed(nil))
        XCTAssertTrue(executor.ranSteps.isEmpty)

        store.failsSavingIntent = false
        coordinator.retry()
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(executor.finishedReasons, [.pinAttemptsExceeded])
    }

    func testUnreadablePinLockoutStateAtLaunchBlocksWithoutDeletingAnything() async {
        for failsLoadingPin in [false, true] {
            resetFixtures()
            store.failedAttempts = Env.pinAttempts
            store.failsLoadingPin = failsLoadingPin
            store.failsLoadingAttempts = !failsLoadingPin
            var madeExecutor = false
            let coordinator = WipeCoordinator(store: store, makeExecutor: {
                madeExecutor = true
                return nil
            }, retryDelays: [])

            let launchesNormally = await coordinator.prepareForLaunch()

            XCTAssertFalse(launchesNormally, "Holds the launch and the node start, failsLoadingPin: \(failsLoadingPin)")
            XCTAssertEqual(coordinator.gate, .blocked, "failsLoadingPin: \(failsLoadingPin)")
            XCTAssertTrue(coordinator.didHoldLaunch, "failsLoadingPin: \(failsLoadingPin)")
            XCTAssertFalse(madeExecutor, "failsLoadingPin: \(failsLoadingPin)")
            XCTAssertNil(store.intent, "failsLoadingPin: \(failsLoadingPin)")
            XCTAssertEqual(store.pin, "1234", "failsLoadingPin: \(failsLoadingPin)")
            XCTAssertEqual(store.failedAttempts, Env.pinAttempts, "failsLoadingPin: \(failsLoadingPin)")
        }
    }

    func testUnreadableCounterThatLaterReadsExhaustedRunsTheForcedWipe() async throws {
        store.failedAttempts = Env.pinAttempts
        store.failsLoadingAttempts = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [.milliseconds(10), .milliseconds(10)])
        var gates: [WipeCoordinator.Gate] = []
        let observation = coordinator.$gate.sink { gates.append($0) }
        defer { observation.cancel() }

        let launchesNormally = await coordinator.prepareForLaunch()
        XCTAssertFalse(launchesNormally)

        coordinator.retry()
        XCTAssertEqual(coordinator.gate, .blocked, "A counter that still cannot be read keeps access blocked")
        XCTAssertTrue(executor.ranSteps.isEmpty)
        XCTAssertNil(store.intent)

        // Only the retry the block scheduled reads the counter again.
        store.failsLoadingAttempts = false
        for _ in 0 ..< 200 where coordinator.gate != .none {
            try await Task.sleep(for: .milliseconds(10))
            await coordinator.waitForCurrentAttempt()
        }

        XCTAssertEqual(gates, [.none, .blocked, .wiping, .none], "The block lifts only once the wipe has completed")
        XCTAssertEqual(executor.intentReasonAtFirstStep, .pinAttemptsExceeded)
        XCTAssertEqual(executor.finishedReasons, [.pinAttemptsExceeded])
        XCTAssertNil(store.pin)
    }

    func testUnreadableCounterThatLaterReadsBelowTheLimitLowersTheGateToAPinLaunch() async throws {
        store.failedAttempts = Env.pinAttempts - 1
        store.failsLoadingAttempts = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [.milliseconds(10)])

        let launchesNormally = await coordinator.prepareForLaunch()
        XCTAssertFalse(launchesNormally)

        store.failsLoadingAttempts = false
        for _ in 0 ..< 200 where coordinator.gate != .none {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.gate, .none)
        XCTAssertTrue(coordinator.didHoldLaunch, "The held launch starts over")
        let relaunchesNormally = await coordinator.prepareForLaunch()
        XCTAssertTrue(relaunchesNormally, "The launch goes on to the PIN check")
        XCTAssertEqual(PinVerifier(store: store, coordinator: coordinator).verify("1234"), .correct)
        XCTAssertTrue(executor.ranSteps.isEmpty)
        XCTAssertNil(store.intent)
    }

    func testCounterIsNotPromotedWithoutAPinOrBelowTheLimit() async {
        for (pin, attempts) in [(nil, Env.pinAttempts), ("1234", Env.pinAttempts - 1)] {
            resetFixtures()
            store.pin = pin
            store.failedAttempts = attempts
            let executor = RecordingWipeExecutor(device: device)

            let launchesNormally = await makeCoordinator(executor).prepareForLaunch()

            XCTAssertTrue(launchesNormally, "pin: \(String(describing: pin)), attempts: \(attempts)")
            XCTAssertTrue(executor.ranSteps.isEmpty)
            XCTAssertNil(store.intent)
        }
    }

    // MARK: - Retrying and resetting

    func testScheduledRetriesGoOnAtTheLongestDelay() async throws {
        let executor = RecordingWipeExecutor(device: device)
        executor.failingSteps = [.wipeDatabases]
        let coordinator = WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [.milliseconds(5)])

        try coordinator.begin(.userReset)
        for _ in 0 ..< 400 where executor.ranSteps.filter({ $0 == .wipeLightningStorage }).count < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertGreaterThanOrEqual(executor.ranSteps.filter { $0 == .wipeLightningStorage }.count, 4, "Each attempt reaches the failing step")
        executor.failingSteps = []
        for _ in 0 ..< 400 where coordinator.gate != .none {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.gate, .none)
    }

    func testARetryShowsTheWipeRunningAgainRatherThanTheLastFailure() async throws {
        let executor = RecordingWipeExecutor(device: device)
        executor.failingSteps = [.wipeDatabases]
        let coordinator = makeCoordinator(executor)
        try coordinator.begin(.userReset)
        await coordinator.waitForCurrentAttempt()
        XCTAssertEqual(coordinator.progress, .failed(.wipeDatabases))

        coordinator.retry()

        XCTAssertEqual(coordinator.progress, .running(.quiesce))
        await coordinator.waitForCurrentAttempt()
    }

    func testABlockedGateCanBeResetIntoAWipe() async throws {
        store.failsLoadingIntent = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)
        _ = await coordinator.prepareForLaunch()
        XCTAssertEqual(coordinator.gate, .blocked)
        store.failsLoadingIntent = false

        try coordinator.resetFromBlockedGate()
        XCTAssertEqual(coordinator.gate, .wiping)
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(coordinator.gate, .none)
        XCTAssertEqual(executor.finishedReasons, [.forgotPin])
        XCTAssertNil(store.intent)
    }

    func testAResetFromTheBlockedGateWhoseIntentCannotBeWrittenStaysBlocked() async {
        store.failsLoadingAttempts = true
        let executor = RecordingWipeExecutor(device: device)
        let coordinator = makeCoordinator(executor)
        _ = await coordinator.prepareForLaunch()
        XCTAssertEqual(coordinator.gate, .blocked)
        store.failsSavingIntent = true

        XCTAssertThrowsError(try coordinator.resetFromBlockedGate())

        XCTAssertEqual(coordinator.gate, .blocked)
        XCTAssertTrue(executor.ranSteps.isEmpty)
    }
}
