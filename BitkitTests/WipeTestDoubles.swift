@testable import Bitkit
import Foundation

/// In-memory lockout state for the PIN verifier and wipe coordinator tests. They never write the real `wipe_pending`
/// entry: the host app reads it at launch, and a leftover one would wipe the developer's app settings.
final class FakePinLockoutStore: PinLockoutStore {
    struct Failure: Error {}

    var pin: String?
    var failedAttempts = 0
    var intent: Data?
    var failsLoadingPin = false
    var failsLoadingAttempts = false
    var failsSavingAttempts = false
    var failsResettingAttempts = false
    var failsLoadingIntent = false
    var failsSavingIntent = false
    /// Accepts the write but reads back nothing, like a keychain that silently dropped it.
    var dropsSavedIntent = false

    func loadPin() throws -> String? {
        if failsLoadingPin { throw Failure() }
        return pin
    }

    func loadFailedAttempts() throws -> Int {
        if failsLoadingAttempts { throw Failure() }
        return failedAttempts
    }

    func saveFailedAttempts(_ count: Int) throws {
        if failsSavingAttempts || (failsResettingAttempts && count == 0) { throw Failure() }
        failedAttempts = count
    }

    func deleteFailedAttempts() throws {
        failedAttempts = 0
    }

    func loadWipeIntent() throws -> Data? {
        if failsLoadingIntent { throw Failure() }
        return intent
    }

    func saveWipeIntent(_ data: Data) throws {
        if failsSavingIntent { throw Failure() }
        if !dropsSavedIntent { intent = data }
    }

    var intentReason: WipeReason? {
        intent.flatMap { try? JSONDecoder().decode(WipeIntent.self, from: $0) }?.reason
    }
}

/// The wallet a wipe deletes, with the order each piece went in, shared by every executor a test builds so it outlives a
/// simulated kill.
@MainActor
final class FakeWipedDevice {
    let store: FakePinLockoutStore
    var deletions: [String] = []
    /// Whether every step started with the intent present, and with the PIN present until a `deletePin` step had run.
    var lockoutHeldUntilItsStep = true

    init(store: FakePinLockoutStore) {
        self.store = store
    }
}

@MainActor
final class RecordingWipeExecutor: WipeStepExecutor {
    struct StepFailure: Error {}

    let device: FakeWipedDevice
    var failingSteps: Set<WipeStep> = []
    /// Throws right after this step has done its work, as a process killed there would leave it.
    var killedAfter: WipeStep?
    private(set) var ranSteps: [WipeStep] = []
    private(set) var scopeEntries = 0
    private(set) var finishedReasons: [WipeReason?] = []
    private(set) var intentReasonAtFirstStep: WipeReason?

    init(device: FakeWipedDevice) {
        self.device = device
    }

    func withWipeScope(_ steps: () async throws -> Void) async throws {
        scopeEntries += 1
        try await steps()
    }

    func run(_ step: WipeStep) async throws {
        if ranSteps.isEmpty {
            intentReasonAtFirstStep = device.store.intentReason
        }
        if device.store.intent == nil || (!device.deletions.contains("pin") && device.store.pin == nil) {
            device.lockoutHeldUntilItsStep = false
        }
        if failingSteps.contains(step) {
            throw StepFailure()
        }

        ranSteps.append(step)
        switch step {
        case .wipeKeychain:
            device.deletions.append("mnemonic")
        case .resetSettings:
            device.deletions.append("settings")
        case .deletePin:
            device.store.pin = nil
            device.store.failedAttempts = 0
            device.deletions.append("pin")
        case .commit:
            device.store.intent = nil
            device.deletions.append("intent")
        default:
            break
        }

        if step == killedAfter {
            throw StepFailure()
        }
    }

    func finish(reason: WipeReason?) {
        finishedReasons.append(reason)
    }
}
