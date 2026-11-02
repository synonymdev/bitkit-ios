@testable import Bitkit
import XCTest

@MainActor
final class PinVerifierTests: XCTestCase {
    private var store: FakePinLockoutStore!
    private var executor: RecordingWipeExecutor!
    private var coordinator: WipeCoordinator!
    private var verifier: PinVerifier!

    override func setUp() {
        super.setUp()
        resetFixtures()
    }

    private func resetFixtures() {
        store = FakePinLockoutStore()
        store.pin = "1234"
        executor = RecordingWipeExecutor(device: FakeWipedDevice(store: store))
        coordinator = makeCoordinator()
        verifier = PinVerifier(store: store, coordinator: coordinator)
    }

    private func makeCoordinator() -> WipeCoordinator {
        WipeCoordinator(store: store, makeExecutor: { [executor] in executor }, retryDelays: [])
    }

    // MARK: - Counting

    func testCorrectPinUnderTheLimitResetsTheCounter() {
        store.failedAttempts = 3

        XCTAssertEqual(verifier.verify("1234"), .correct)
        XCTAssertEqual(store.failedAttempts, 0)
    }

    func testWrongPinIsRecordedBeforeTheResultReturns() {
        XCTAssertEqual(verifier.verify("0000"), .incorrect(remaining: Env.pinAttempts - 1))
        XCTAssertEqual(store.failedAttempts, 1)

        XCTAssertEqual(verifier.verify("0000"), .incorrect(remaining: Env.pinAttempts - 2))
        XCTAssertEqual(store.failedAttempts, 2)
    }

    // MARK: - Exhaustion

    func testLastWrongPinConfirmsTheWipeIntentBeforeReturning() async {
        store.failedAttempts = Env.pinAttempts - 1

        XCTAssertEqual(verifier.verify("0000"), .lockedOut)
        XCTAssertEqual(store.failedAttempts, Env.pinAttempts)
        XCTAssertEqual(store.intentReason, .pinAttemptsExceeded)
        XCTAssertEqual(coordinator.gate, .wiping)
        XCTAssertTrue(executor.ranSteps.isEmpty, "The intent is durable before any step runs")

        await coordinator.waitForCurrentAttempt()
        XCTAssertEqual(executor.intentReasonAtFirstStep, .pinAttemptsExceeded)
    }

    func testLastWrongPinWhoseIntentCannotBeWrittenLocksOutUntilARelaunchPromotesIt() async {
        for dropsWrite in [false, true] {
            resetFixtures()
            store.failedAttempts = Env.pinAttempts - 1
            store.failsSavingIntent = !dropsWrite
            store.dropsSavedIntent = dropsWrite

            XCTAssertEqual(verifier.verify("0000"), .lockedOut, "dropsWrite: \(dropsWrite)")
            await coordinator.waitForCurrentAttempt()

            XCTAssertTrue(executor.ranSteps.isEmpty, "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(coordinator.gate, .wiping, "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(coordinator.progress, .failed(nil), "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(verifier.verify("1234"), .lockedOut, "dropsWrite: \(dropsWrite)")
            XCTAssertFalse(verifier.canUseBiometrics, "dropsWrite: \(dropsWrite)")

            store.failsSavingIntent = false
            store.dropsSavedIntent = false
            let relaunched = makeCoordinator()
            let launchesNormally = await relaunched.prepareForLaunch()

            XCTAssertFalse(launchesNormally, "dropsWrite: \(dropsWrite)")
            XCTAssertEqual(executor.finishedReasons, [.pinAttemptsExceeded], "dropsWrite: \(dropsWrite)")
        }
    }

    func testCorrectPinAfterExhaustionIsLockedOutAndKeepsTheCounter() async {
        store.failedAttempts = Env.pinAttempts

        XCTAssertEqual(verifier.verify("1234"), .lockedOut)
        XCTAssertEqual(store.failedAttempts, Env.pinAttempts)
        XCTAssertEqual(store.intentReason, .pinAttemptsExceeded)

        await coordinator.waitForCurrentAttempt()
    }

    func testPendingWipeLocksOutWithoutComparing() async {
        store.intent = try? JSONEncoder().encode(WipeIntent(reason: .userReset, startedAt: 0))
        store.failedAttempts = 2

        XCTAssertEqual(verifier.verify("1234"), .lockedOut)
        XCTAssertEqual(verifier.verify("0000"), .lockedOut)
        XCTAssertEqual(store.failedAttempts, 2)
        XCTAssertEqual(coordinator.gate, .wiping)

        await coordinator.waitForCurrentAttempt()
    }

    func testUnreadableIntentLocksOutWithoutStartingAWipe() async {
        store.failsLoadingIntent = true

        XCTAssertEqual(verifier.verify("1234"), .lockedOut)
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(coordinator.gate, .blocked)
        XCTAssertEqual(store.failedAttempts, 0)
        XCTAssertTrue(executor.ranSteps.isEmpty)
    }

    // MARK: - Biometrics

    func testBiometricsAreRefusedOnceExhaustedOrWhileAWipeIsPending() {
        XCTAssertTrue(verifier.canUseBiometrics)

        store.failedAttempts = Env.pinAttempts
        XCTAssertFalse(verifier.canUseBiometrics)

        store.failedAttempts = 0
        store.intent = try? JSONEncoder().encode(WipeIntent(reason: .userReset, startedAt: 0))
        XCTAssertFalse(verifier.canUseBiometrics)

        store.intent = nil
        store.failsLoadingIntent = true
        XCTAssertFalse(verifier.canUseBiometrics)
    }

    // MARK: - Unreadable state

    func testUnreadableStateIsUnavailableAndLeavesTheCounter() {
        store.failedAttempts = 2
        store.failsLoadingAttempts = true
        XCTAssertEqual(verifier.verify("1234"), .unavailable)

        store.failsLoadingAttempts = false
        store.failsLoadingPin = true
        XCTAssertEqual(verifier.verify("0000"), .unavailable)
        XCTAssertEqual(store.failedAttempts, 2)
        XCTAssertEqual(coordinator.gate, .none)
    }

    func testFailedAttemptThatCannotBeRecordedBlocksAccessForTheProcess() {
        store.failsSavingAttempts = true

        XCTAssertEqual(verifier.verify("0000"), .unavailable)
        XCTAssertEqual(coordinator.gate, .blocked)
        XCTAssertEqual(verifier.verify("1234"), .lockedOut)

        coordinator.retry()
        XCTAssertEqual(coordinator.gate, .blocked)
        XCTAssertFalse(verifier.canUseBiometrics)
    }

    func testAnAttemptThatCannotBeRecordedIsNeverCompared() {
        store.failsSavingAttempts = true

        XCTAssertEqual(verifier.verify("1234"), .unavailable, "A correct PIN must not unlock while its attempt goes unrecorded")
        XCTAssertEqual(store.failedAttempts, 0)
        XCTAssertEqual(coordinator.gate, .blocked)
    }

    func testCorrectPinIsCountedBeforeTheComparisonThenCleared() {
        store.failedAttempts = Env.pinAttempts - 1

        XCTAssertEqual(verifier.verify("1234"), .correct)
        XCTAssertEqual(store.failedAttempts, 0)
        XCTAssertEqual(coordinator.gate, .none)
    }

    // MARK: - Keychain store

    func testKeychainStoreReadsTheHigherOfTheLegacyAndKeychainCountersUntilTheNextWrite() throws {
        let defaults = try makeIsolatedDefaults()
        let keychainStore = KeychainPinLockoutStore(defaults: defaults)
        try Keychain.delete(key: .pinFailedAttempts)
        addTeardownBlock { try? Keychain.delete(key: .pinFailedAttempts) }

        defaults.set(5, forKey: KeychainPinLockoutStore.legacyFailedAttemptsKey)
        XCTAssertEqual(try keychainStore.loadFailedAttempts(), 5)

        try keychainStore.saveFailedAttempts(3)
        XCTAssertNil(defaults.object(forKey: KeychainPinLockoutStore.legacyFailedAttemptsKey))
        XCTAssertEqual(try keychainStore.loadFailedAttempts(), 3)

        defaults.set(2, forKey: KeychainPinLockoutStore.legacyFailedAttemptsKey)
        XCTAssertEqual(try keychainStore.loadFailedAttempts(), 3)
    }
}
