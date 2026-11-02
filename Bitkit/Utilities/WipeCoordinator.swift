import Foundation

/// A wait a wipe step makes did not end in time. The step fails before it deletes anything, and the wipe stays pending.
struct WipeWaitTimeoutError: Error {
    let wait: String
}

enum WipeReason: String, Codable {
    case pinAttemptsExceeded
    case userReset
    case forgotPin
    case recoveryReset
    case dev
}

/// The value stored under `wipe_pending`. The entry's presence alone is the request: a value that no longer decodes still
/// means a wipe was asked for, and `lastStep` is only ever logged, never used to skip a step.
struct WipeIntent: Codable, Equatable {
    var v = 1
    let reason: WipeReason
    let startedAt: Int
    var lastStep: String?
}

enum WipeIntentState {
    case none
    /// `nil` when the stored value cannot be decoded.
    case confirmed(WipeIntent?)
    /// The keychain could not be read. Blocks access, and never authorises a deletion.
    case unknown(Error)
}

/// A wipe in the only order that a kill at any point can resume from: the mnemonic goes before settings, settings before
/// the PIN, and the intent last, so every relaunch before `commit` still finds the gate and the PIN.
enum WipeStep: String, CaseIterable {
    case quiesce
    case stopNode
    case removeRemoteEndpoints
    case resetLocalServices
    case wipeLightningStorage
    case wipeDatabases
    case clearPubkyState
    case wipeKeychain
    case resetSettings
    case deletePin
    case deleteInstallationMarker
    case commit
}

@MainActor
protocol WipeStepExecutor {
    /// Runs `steps` with uploads, node starts and Paykit work shut out.
    func withWipeScope(_ steps: () async throws -> Void) async throws
    /// Every step is idempotent: a resumed wipe runs all of them again.
    func run(_ step: WipeStep) async throws
    /// Resets the in-memory app once the intent is gone.
    func finish(reason: WipeReason?)
}

/// Owns every wallet wipe for the life of the process, outside the app state tree that the wipe recreates. A wipe runs only
/// once its intent has been written and read back, keeps the app behind the gate until it completes, and retries a failed
/// step instead of ever returning to PIN entry.
@MainActor
final class WipeCoordinator: ObservableObject {
    enum Gate: Equatable {
        case none
        /// A wipe is requested: it runs, or waits to retry, and nothing else is reachable until it completes.
        case wiping
        /// Access is blocked, but the lockout state could not be read or recorded, so nothing may be deleted.
        case blocked
    }

    enum Progress: Equatable {
        case idle
        case running(WipeStep)
        /// `nil` while the intent itself could not be written, so nothing has been deleted.
        case failed(WipeStep?)
    }

    private enum PinAttemptsState {
        case notExhausted
        case exhausted
        case unreadable
    }

    static let shared = WipeCoordinator(store: KeychainPinLockoutStore(), makeExecutor: AppReset.attached)

    @Published private(set) var gate: Gate = .none
    @Published private(set) var progress: Progress = .idle
    /// Whether the last launch stopped at an unreadable lockout state. Only such a launch starts over when the block
    /// lifts: one raised later lifts over a session that is already running.
    private(set) var didHoldLaunch = false

    private let store: PinLockoutStore
    private let makeExecutor: () -> WipeStepExecutor?
    private let retryDelays: [Duration]
    private var reason: WipeReason?
    private var isIntentDurable = false
    private var attempt: Task<Void, Never>?
    private var scheduledRetry: Task<Void, Never>?
    private var scheduledRetryCount = 0
    private var isBlockedUntilRelaunch = false

    var isGateUp: Bool {
        gate != .none
    }

    init(
        store: PinLockoutStore,
        makeExecutor: @escaping () -> WipeStepExecutor?,
        retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
    ) {
        self.store = store
        self.makeExecutor = makeExecutor
        self.retryDelays = retryDelays
    }

    // MARK: - Entry points

    /// Settles the wipe state before anything reads or starts the wallet. Returns whether the app may launch normally.
    func prepareForLaunch() async -> Bool {
        didHoldLaunch = gate == .blocked
        guard gate == .none else { return false }

        switch applyPersistedIntent() {
        case .none:
            switch applyPinAttemptsState() {
            case .notExhausted:
                return true
            case .exhausted:
                break
            case .unreadable:
                didHoldLaunch = true
                return false
            }
        case .confirmed:
            break
        case .unknown:
            didHoldLaunch = true
            return false
        }

        await waitForCurrentAttempt()
        return false
    }

    /// Starts a wipe the user asked for. Throws, with nothing deleted, when the intent cannot be made durable.
    func begin(_ reason: WipeReason) throws {
        guard gate == .none else {
            Logger.info("Wipe already pending, not starting another", context: "WipeCoordinator")
            return
        }

        try writeIntent(reason)
        enterWipe(reason: reason)
        isIntentDurable = true
        startAttempt()
    }

    /// Locks this process out at once, and starts the wipe only once its intent reads back. Until it does, the wipe is
    /// retried from the durably exhausted counter, here and at the next launch.
    func lockOutAfterExhaustedPinAttempts() {
        guard gate != .wiping else { return }
        enterWipe(reason: .pinAttemptsExceeded)
        writeIntentAndStart()
    }

    /// Blocks access for the rest of this process without starting a wipe, for a failed PIN attempt that could not be
    /// recorded: another entry would be a guess the counter never sees.
    func blockAccess() {
        isBlockedUntilRelaunch = true
        guard gate == .none else { return }
        gate = .blocked
    }

    /// Runs the next attempt now, for the gate's Retry button or a return to the foreground. Scheduled retries start over
    /// from the shortest delay.
    func retry() {
        scheduledRetryCount = 0
        runNextAttempt()
    }

    /// Starts a wipe from the blocked gate, which deletes the wallet rather than unlocking it. Throws, with nothing deleted and
    /// access still blocked, when the intent cannot be made durable.
    func resetFromBlockedGate() throws {
        guard gate == .blocked else { return }
        try writeIntent(.forgotPin)
        enterWipe(reason: .forgotPin)
        isIntentDurable = true
        startAttempt()
    }

    private func runNextAttempt() {
        scheduledRetry?.cancel()
        scheduledRetry = nil

        switch gate {
        case .none:
            return
        case .blocked:
            applyPersistedIntent()
        case .wiping:
            guard attempt == nil else { return }
            if isIntentDurable {
                startAttempt()
            } else {
                writeIntentAndStart()
            }
        }
    }

    func waitForCurrentAttempt() async {
        await attempt?.value
    }

    // MARK: - Intent

    func readIntent() -> WipeIntentState {
        do {
            guard let data = try store.loadWipeIntent() else { return .none }
            return .confirmed(try? JSONDecoder().decode(WipeIntent.self, from: data))
        } catch {
            Logger.error("Failed to read the wipe intent: \(error)", context: "WipeCoordinator")
            return .unknown(error)
        }
    }

    /// Reads the intent and acts on it: a pending wipe raises the gate and resumes, an unreadable one blocks access.
    @discardableResult
    func applyPersistedIntent() -> WipeIntentState {
        let state = readIntent()

        switch state {
        case .none:
            // A launch held by the block skipped the PIN lockout check, so it runs before the block lifts.
            if gate == .blocked, applyPinAttemptsState() == .notExhausted, !isBlockedUntilRelaunch {
                gate = .none
            }
        case let .confirmed(intent):
            guard gate != .wiping else { break }
            Logger.warn(
                "Resuming wipe, reason: \(intent?.reason.rawValue ?? "unreadable"), last step: \(intent?.lastStep ?? "none")",
                context: "WipeCoordinator"
            )
            enterWipe(reason: intent?.reason)
            isIntentDurable = true
            startAttempt()
        case .unknown:
            guard gate != .wiping else { break }
            blockUntilReadable()
        }

        return state
    }

    private func writeIntent(_ reason: WipeReason) throws {
        let data = try JSONEncoder().encode(WipeIntent(reason: reason, startedAt: Int(Date().timeIntervalSince1970)))
        try store.saveWipeIntent(data)
        guard try store.loadWipeIntent() == data else {
            throw KeychainError.failedToSave
        }
    }

    private func writeIntentAndStart() {
        guard let reason else { return }

        do {
            try writeIntent(reason)
        } catch {
            Logger.error("Failed to write the wipe intent, nothing is deleted until it is: \(error)", context: "WipeCoordinator")
            progress = .failed(nil)
            scheduleRetry()
            return
        }

        isIntentDurable = true
        startAttempt()
    }

    private func recordLastStep(_ step: WipeStep) {
        guard let data = try? store.loadWipeIntent(), var intent = try? JSONDecoder().decode(WipeIntent.self, from: data) else {
            return
        }
        intent.lastStep = step.rawValue
        if let updated = try? JSONEncoder().encode(intent) {
            try? store.saveWipeIntent(updated)
        }
    }

    private func applyPinAttemptsState() -> PinAttemptsState {
        let state = readPinAttemptsState()

        switch state {
        case .notExhausted:
            break
        case .exhausted:
            Logger.warn("PIN attempts exhausted without a pending wipe, starting it", context: "WipeCoordinator")
            lockOutAfterExhaustedPinAttempts()
        case .unreadable:
            blockUntilReadable()
        }

        return state
    }

    private func readPinAttemptsState() -> PinAttemptsState {
        do {
            guard try store.loadPin() != nil else { return .notExhausted }
            return try store.loadFailedAttempts() >= Env.pinAttempts ? .exhausted : .notExhausted
        } catch {
            Logger.error("Failed to read the PIN lockout state: \(error)", context: "WipeCoordinator")
            return .unreadable
        }
    }

    private func blockUntilReadable() {
        if gate == .none {
            scheduledRetryCount = 0
            gate = .blocked
        }
        scheduleRetry()
    }

    // MARK: - Attempts

    private func enterWipe(reason: WipeReason?) {
        self.reason = reason
        isIntentDurable = false
        scheduledRetryCount = 0
        gate = .wiping
    }

    private func startAttempt() {
        guard attempt == nil else { return }
        scheduledRetry?.cancel()
        scheduledRetry = nil
        progress = .running(.quiesce)
        attempt = Task {
            await runAttempt()
            attempt = nil
        }
    }

    private func runAttempt() async {
        guard let executor = makeExecutor() else {
            Logger.error("No app state to wipe yet", context: "WipeCoordinator")
            progress = .failed(.quiesce)
            scheduleRetry()
            return
        }

        var currentStep = WipeStep.quiesce
        do {
            try await executor.withWipeScope {
                for step in WipeStep.allCases {
                    currentStep = step
                    progress = .running(step)
                    recordLastStep(step)
                    Logger.info("Wipe step: \(step.rawValue)", context: "WipeCoordinator")
                    try await executor.run(step)
                }
            }
        } catch {
            Logger.error("Wipe failed at \(currentStep.rawValue), it stays pending: \(error)", context: "WipeCoordinator")
            progress = .failed(currentStep)
            scheduleRetry()
            return
        }

        Logger.info("Wipe completed", context: "WipeCoordinator")
        let completedReason = reason
        reason = nil
        isIntentDurable = false
        isBlockedUntilRelaunch = false
        progress = .idle
        gate = .none
        executor.finish(reason: completedReason)
    }

    private func scheduleRetry() {
        guard let longestDelay = retryDelays.last else { return }
        let delay = scheduledRetryCount < retryDelays.count ? retryDelays[scheduledRetryCount] : longestDelay
        scheduledRetryCount += 1

        scheduledRetry?.cancel()
        scheduledRetry = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            runNextAttempt()
        }
    }
}
