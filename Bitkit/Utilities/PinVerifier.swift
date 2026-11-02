import Foundation

enum PinResult: Equatable {
    case correct
    case incorrect(remaining: Int)
    /// No PIN unlocks any more: attempts are exhausted, or a wipe is pending or cannot be ruled out.
    case lockedOut
    /// The lockout state could not be read or recorded. Nothing unlocks.
    case unavailable
}

/// The persisted state the PIN lockout depends on. A read that fails throws: it never stands for "absent".
protocol PinLockoutStore {
    func loadPin() throws -> String?
    func loadFailedAttempts() throws -> Int
    func saveFailedAttempts(_ count: Int) throws
    func loadWipeIntent() throws -> Data?
    func saveWipeIntent(_ data: Data) throws
}

struct KeychainPinLockoutStore: PinLockoutStore {
    /// Where releases before the keychain counter kept it.
    static let legacyFailedAttemptsKey = "pinFailedAttempts"

    var defaults: UserDefaults = .standard

    func loadPin() throws -> String? {
        try Keychain.loadString(key: .securityPin)
    }

    /// The higher of the keychain and legacy counters, so an upgrade can only tighten the lockout. A counter that does not
    /// parse counts as exhausted.
    func loadFailedAttempts() throws -> Int {
        let stored = try Keychain.loadString(key: .pinFailedAttempts).map { Int($0) ?? Env.pinAttempts } ?? 0
        return max(stored, defaults.integer(forKey: Self.legacyFailedAttemptsKey))
    }

    func saveFailedAttempts(_ count: Int) throws {
        let data = Data(String(count).utf8)
        try Keychain.upsert(key: .pinFailedAttempts, data: data)
        guard try Keychain.load(key: .pinFailedAttempts) == data else {
            throw KeychainError.failedToSave
        }
        defaults.removeObject(forKey: Self.legacyFailedAttemptsKey)
    }

    func loadWipeIntent() throws -> Data? {
        try Keychain.load(key: .wipePending)
    }

    func saveWipeIntent(_ data: Data) throws {
        try Keychain.upsert(key: .wipePending, data: data)
    }
}

/// The one place a PIN is checked. Every PIN pad and biometric prompt goes through it, so a lockout holds everywhere.
@MainActor
final class PinVerifier {
    static let shared = PinVerifier(store: KeychainPinLockoutStore(), coordinator: .shared)

    private let store: PinLockoutStore
    private let coordinator: WipeCoordinator

    init(store: PinLockoutStore, coordinator: WipeCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    func verify(_ pin: String) -> PinResult {
        guard !coordinator.isGateUp, case .none = coordinator.applyPersistedIntent() else {
            return .lockedOut
        }

        let failedAttempts: Int
        do {
            failedAttempts = try store.loadFailedAttempts()
        } catch {
            Logger.error("Failed to read the PIN attempt counter: \(error)", context: "PinVerifier")
            return .unavailable
        }

        guard failedAttempts < Env.pinAttempts else {
            coordinator.lockOutAfterExhaustedPinAttempts()
            return .lockedOut
        }

        let storedPin: String?
        do {
            storedPin = try store.loadPin()
        } catch {
            Logger.error("Failed to load the PIN: \(error)", context: "PinVerifier")
            return .unavailable
        }

        guard let storedPin else {
            Logger.error("No PIN stored to verify against", context: "PinVerifier")
            return .unavailable
        }

        // Recorded before the comparison, so an attempt whose record fails is never compared: a write that keeps failing would
        // otherwise allow a guess per launch.
        let newFailedAttempts = failedAttempts + 1
        do {
            try store.saveFailedAttempts(newFailedAttempts)
        } catch {
            Logger.error("Failed to record a PIN attempt: \(error)", context: "PinVerifier")
            coordinator.blockAccess()
            return .unavailable
        }

        if storedPin == pin {
            do {
                try store.saveFailedAttempts(0)
            } catch {
                // Leaving the counter raised only keeps the lockout stricter.
                Logger.error("Failed to reset the PIN attempt counter: \(error)", context: "PinVerifier")
            }
            return .correct
        }

        guard newFailedAttempts < Env.pinAttempts else {
            coordinator.lockOutAfterExhaustedPinAttempts()
            return .lockedOut
        }

        return .incorrect(remaining: Env.pinAttempts - newFailedAttempts)
    }

    /// False once attempts are exhausted or a wipe is pending or unverifiable, so biometrics can never stand in for a
    /// PIN that may no longer be entered.
    var canUseBiometrics: Bool {
        guard !coordinator.isGateUp, case .none = coordinator.readIntent() else { return false }
        guard let failedAttempts = try? store.loadFailedAttempts() else { return false }
        return failedAttempts < Env.pinAttempts
    }
}
