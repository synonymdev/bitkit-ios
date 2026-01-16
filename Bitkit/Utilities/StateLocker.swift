import Foundation

enum StateLockerError: Error, Equatable {
    case alreadyLocked(processName: String)
    case differentEnvironmentLocked
    case staleLock

    static func == (lhs: StateLockerError, rhs: StateLockerError) -> Bool {
        switch (lhs, rhs) {
        case let (.alreadyLocked(lhsProcess), .alreadyLocked(rhsProcess)):
            return lhsProcess == rhsProcess
        case (.differentEnvironmentLocked, .differentEnvironmentLocked):
            return true
        case (.staleLock, .staleLock):
            return true
        default:
            return false
        }
    }
}

extension StateLockerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .alreadyLocked(processName):
            return "State already locked by process: \(processName)"
        case .differentEnvironmentLocked:
            return "Different environment has the lock"
        case .staleLock:
            return "Stale lock"
        }
    }
}

public enum ExecutionContext: String, Codable {
    case foregroundApp
    case pushNotificationExtension

    var expiryTime: TimeInterval {
        switch self {
        case .pushNotificationExtension:
            return 35 // Should never run over 30s
        case .foregroundApp:
            return 5 * 60 // TODO: test this out
        }
    }

    // For log file names
    var filenamePrefix: String {
        switch self {
        case .foregroundApp:
            return "foreground"
        case .pushNotificationExtension:
            return "background"
        }
    }
}

class StateLocker {
    enum ProcessType: String {
        case lightning
        case onchain
        // Any other process shared in background tasks
    }

    #if UNIT_TESTING
        static var unitTestCustomDate = Date()
        static func injectTestDate(_ date: Date) {
            unitTestCustomDate = date
        }

        static var unitTestCustomExecutionContext: ExecutionContext?

        /// Allows unit tests to override the execution context returned by Env.currentExecutionContext
        /// When used in unit tests, this value will be checked and used if set
        static func injectTestEnvironment(_ environment: ExecutionContext?) {
            unitTestCustomExecutionContext = environment
        }

        /// Returns the current execution context, using the injected test context if available
        static var currentExecutionContext: ExecutionContext {
            return unitTestCustomExecutionContext ?? Env.currentExecutionContext
        }
    #else
        /// Returns the current execution context from Env
        static var currentExecutionContext: ExecutionContext {
            return Env.currentExecutionContext
        }
    #endif

    private struct LockFileContent: Codable {
        let environment: ExecutionContext
        let date: Date
        var isExpired: Bool {
            return Date().timeIntervalSince(date) > environment.expiryTime
        }

        init() {
            #if UNIT_TESTING
                environment = StateLocker.currentExecutionContext
                date = StateLocker.unitTestCustomDate
            #else
                environment = Env.currentExecutionContext
                date = Date()
            #endif
        }
    }

    private static func lockfile(_ process: ProcessType) -> URL {
        if !FileManager.default.fileExists(atPath: Env.appStorageUrl.path) {
            try? FileManager.default.createDirectory(at: Env.appStorageUrl, withIntermediateDirectories: true)
        }

        return Env.appStorageUrl.appendingPathComponent("\(process.rawValue).lock")
    }

    private static func lockFileContent(_ process: ProcessType) -> LockFileContent? {
        guard let data = try? Data(contentsOf: lockfile(process)) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(LockFileContent.self, from: data)
    }

    private static func writeLockFile(_ process: ProcessType) throws {
        let lockContent = LockFileContent()
        let data = try JSONEncoder().encode(lockContent)
        try data.write(to: lockfile(process), options: .atomic)
    }

    /// Attempts to acquire a lock for the specified process.
    /// - Parameters:
    ///   - process: The type of process to lock.
    ///   - wait: The maximum time to wait for the lock to become available, in seconds.
    /// - Throws: `StateLockerError.alreadyLocked` if the lock cannot be acquired within the wait time,
    ///           or other errors related to file operations.
    static func lock(_ process: ProcessType, wait: TimeInterval) async throws {
        Logger.debug("🔒 Attempting to lock process: \(process.rawValue) with wait time: \(wait)s")

        // Check if the process is already locked
        if let existingLock = lockFileContent(process) {
            // If the lock is held by the same execution context, allow it
            if existingLock.environment == StateLocker.currentExecutionContext {
                Logger.debug("🔒 Process \(process.rawValue) is already locked by same context, allowing lock")
                try writeLockFile(process)
                Logger.debug("🔒 Successfully updated lock for process: \(process.rawValue)")
                return
            }

            // Different environment has the lock, wait to acquire it
            Logger.debug("🔒 Process \(process.rawValue) is locked by different context, waiting up to \(wait)s for it to become available")
            let startTime = Date()
            let pollIntervalNanoseconds: UInt64 = 100_000_000 // 0.1 seconds
            while isLocked(process) {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed >= wait {
                    Logger.warn("🔒 Failed to acquire lock for process \(process.rawValue) after waiting \(elapsed)s")
                    throw StateLockerError.alreadyLocked(processName: process.rawValue)
                }
                // Sleep for a short duration before retrying (non-blocking)
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }

        try writeLockFile(process)
        Logger.debug("🔒 Successfully locked process: \(process.rawValue)")
    }

    static func unlock(_ process: ProcessType) throws {
        Logger.debug("🔒 Attempting to unlock process: \(process.rawValue)")

        guard let lock = lockFileContent(process) else {
            Logger.debug("🔒 No lock file found for process \(process.rawValue), nothing to unlock")
            return
        }

        if lock.isExpired {
            // If the lock is expired, we can remove it regardless of the environment
            Logger.debug("🔒 Removing expired lock for process \(process.rawValue)")
            try? FileManager.default.removeItem(at: lockfile(process))
            return
        }

        if lock.environment != StateLocker.currentExecutionContext {
            Logger.warn("🔒 Cannot unlock process \(process.rawValue): locked by different environment (\(lock.environment.rawValue))")
            throw StateLockerError.differentEnvironmentLocked
        }

        do {
            try FileManager.default.removeItem(at: lockfile(process))
            Logger.debug("🔒 Successfully unlocked process: \(process.rawValue)")
        } catch {
            // If we can't delete our own lock, rethrow the original error
            Logger.error("🔒 Failed to unlock process \(process.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    static func isLocked(_ process: ProcessType) -> Bool {
        Logger.debug("🔒 Checking if process is locked: \(process.rawValue)")

        guard let lock = lockFileContent(process) else {
            Logger.debug("🔒 No lock file found for process: \(process.rawValue)")
            return false
        }

        let isExpired = lock.isExpired
        if isExpired {
            Logger.debug("🔒 Lock for process \(process.rawValue) exists but is expired (created: \(lock.date.description))")
        } else {
            Logger.info("🔒 Process \(process.rawValue) is locked by environment: \(lock.environment.rawValue), created: \(lock.date.description)")
        }

        return !isExpired
    }
}
