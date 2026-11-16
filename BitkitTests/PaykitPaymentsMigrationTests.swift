@testable import Bitkit
import XCTest

@MainActor
final class PaykitPaymentsMigrationTests: XCTestCase {
    private enum TransientError: Error { case offline }

    private final class StepsSpy {
        var calls: [String] = []
        var privateResult: Result<Bool, Error> = .success(true)
        var publicResult: Result<Bool, Error> = .success(true)
        var onPrivate: () -> Void = {}

        func makeSteps() -> PaykitPaymentsMigration.Steps {
            PaykitPaymentsMigration.Steps(
                enablePrivate: {
                    self.calls.append("private")
                    self.onPrivate()
                    return try self.privateResult.get()
                },
                enablePublic: {
                    self.calls.append("public")
                    return try self.publicResult.get()
                }
            )
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        PaykitPaymentsMigration.resetLaunchAttemptForTesting()
    }

    override func tearDown() async throws {
        PaykitPaymentsMigration.resetLaunchAttemptForTesting()
        try await super.tearDown()
    }

    // MARK: - Queueing

    func testUpgradeQueuesBothStepsForWalletWithPubkyProfile() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(4, forKey: AppDataMigrations.versionKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertEqual(PaykitPaymentsMigration.plan(defaults: defaults), .init(enablesPrivate: true, enablesPublic: true))
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 5)
    }

    func testUpgradeQueuesNothingWithoutPubkyProfile() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(4, forKey: AppDataMigrations.versionKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false })

        XCTAssertTrue(PaykitPaymentsMigration.plan(defaults: defaults).isEmpty)
    }

    func testMigrationQueuesOnlyOnce() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(4, forKey: AppDataMigrations.versionKey)
        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })
        PaykitPaymentsMigration.clear(defaults: defaults)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertTrue(PaykitPaymentsMigration.plan(defaults: defaults).isEmpty)
    }

    // MARK: - Plan

    func testPlanSkipsPaymentsAlreadyOn() throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)

        XCTAssertTrue(PaykitPaymentsMigration.plan(defaults: defaults).isEmpty)
    }

    func testPlanKeepsPrivateOptOut() throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)

        XCTAssertEqual(PaykitPaymentsMigration.plan(defaults: defaults), .init(enablesPrivate: false, enablesPublic: true))
    }

    func testPlanKeepsPublicChoice() throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        defaults.set(true, forKey: ContactPaymentsService.publicPreferenceChosenKey)

        XCTAssertEqual(PaykitPaymentsMigration.plan(defaults: defaults), .init(enablesPrivate: true, enablesPublic: false))
    }

    // MARK: - Run

    func testRunEnablesBothAndClearsQueue() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertEqual(spy.calls, ["private", "public"])
        XCTAssertFalse(defaults.bool(forKey: PaykitPaymentsMigration.privatePendingKey))
        XCTAssertFalse(defaults.bool(forKey: PaykitPaymentsMigration.publicPendingKey))
    }

    func testRunDoesNothingWhenNotQueued() async throws {
        let defaults = try makeIsolatedDefaults()
        let spy = StepsSpy()

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testRunSkipsOptOutsAndDropsTheirSteps() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
        defaults.set(true, forKey: ContactPaymentsService.publicPreferenceChosenKey)
        let spy = StepsSpy()

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertNil(defaults.object(forKey: PaykitPaymentsMigration.privatePendingKey))
        XCTAssertNil(defaults.object(forKey: PaykitPaymentsMigration.publicPendingKey))
    }

    func testPrivateUnavailableDropsPrivateAndStillEnablesPublic() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()
        spy.privateResult = .failure(PrivatePaykitError.privateUnavailable)

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertEqual(spy.calls, ["private", "public"])
        XCTAssertFalse(defaults.bool(forKey: PaykitPaymentsMigration.privatePendingKey))
        XCTAssertFalse(defaults.bool(forKey: PaykitPaymentsMigration.publicPendingKey))
    }

    func testTransientFailuresStayQueuedForNextLaunch() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()
        spy.privateResult = .failure(TransientError.offline)
        spy.publicResult = .failure(TransientError.offline)

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertEqual(spy.calls, ["private", "public"])
        XCTAssertTrue(defaults.bool(forKey: PaykitPaymentsMigration.privatePendingKey))
        XCTAssertTrue(defaults.bool(forKey: PaykitPaymentsMigration.publicPendingKey))
    }

    func testRunAttemptsOncePerLaunch() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()
        spy.privateResult = .failure(TransientError.offline)
        spy.publicResult = .failure(TransientError.offline)

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })
        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertEqual(spy.calls, ["private", "public"])

        PaykitPaymentsMigration.resetLaunchAttemptForTesting()
        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertEqual(spy.calls, ["private", "public", "private", "public"])
    }

    func testSupersededStepStaysQueued() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()
        spy.privateResult = .success(false)
        spy.publicResult = .success(false)

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertTrue(defaults.bool(forKey: PaykitPaymentsMigration.privatePendingKey))
        XCTAssertTrue(defaults.bool(forKey: PaykitPaymentsMigration.publicPendingKey))
    }

    func testRunDoesNotStartOrCountWhenNotCurrent() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { false })
        XCTAssertTrue(spy.calls.isEmpty)

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })
        XCTAssertEqual(spy.calls, ["private", "public"])
    }

    func testRunStopsBeforePublicWhenSessionEnds() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()
        var isCurrent = true
        spy.onPrivate = { isCurrent = false }

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { isCurrent })

        XCTAssertEqual(spy.calls, ["private"])
        XCTAssertTrue(defaults.bool(forKey: PaykitPaymentsMigration.privatePendingKey))
        XCTAssertTrue(defaults.bool(forKey: PaykitPaymentsMigration.publicPendingKey))
    }

    func testPublicChoiceMadeDuringPrivateStepIsKept() async throws {
        let defaults = try makeIsolatedDefaults()
        PaykitPaymentsMigration.queue(defaults: defaults)
        let spy = StepsSpy()
        spy.onPrivate = { defaults.set(true, forKey: ContactPaymentsService.publicPreferenceChosenKey) }

        await PaykitPaymentsMigration.run(steps: spy.makeSteps(), defaults: defaults, isCurrent: { true })

        XCTAssertEqual(spy.calls, ["private"])
        XCTAssertNil(defaults.object(forKey: PaykitPaymentsMigration.publicPendingKey))
    }
}
