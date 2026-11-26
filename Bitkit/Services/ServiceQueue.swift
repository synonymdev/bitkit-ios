import Foundation
import UIKit

/// Handles app services each on it's own dedicated queue
class ServiceQueue {
    private static let ldkQueue = DispatchQueue(label: "ldk-queue", qos: .userInteractive)
    private static let coreQueue = DispatchQueue(label: "core-queue", qos: .userInteractive)
    private static let migrationQueue = DispatchQueue(label: "migration-queue", qos: .userInteractive)
    private static let forexQueue = DispatchQueue(label: "forex-queue", qos: .userInteractive)
    private static let backupQueue = DispatchQueue(label: "backup-queue", qos: .userInitiated)

    private init() {}

    enum ServiceTypes {
        case ldk
        case core
        case migration
        case forex
        case backup

        var queue: DispatchQueue {
            switch self {
            case .ldk:
                return ServiceQueue.ldkQueue
            case .core:
                return ServiceQueue.coreQueue
            case .migration:
                return ServiceQueue.migrationQueue
            case .forex:
                return ServiceQueue.forexQueue
            case .backup:
                return ServiceQueue.backupQueue
            }
        }

        /// bitkit-core's SQLite databases live in the app group container, and iOS kills an app suspended while it holds a lock on
        /// such a file (0xdead10cc). Work on these queues therefore keeps the app running in the background until it ends.
        var usesDatabases: Bool {
            self == .core || self == .migration
        }
    }

    private static func requestBackgroundTime(for service: ServiceTypes, functionName: String) -> BackgroundTime? {
        service.usesDatabases ? BackgroundTime(name: "\(service) \(functionName)") : nil
    }

    /// Executes a thread blocking function on chosen service queue
    /// - Parameters:
    ///   - service: Queue to run on
    ///   - blocking: The function to run
    ///   - functionName: The name of the function for logging
    /// - Returns: The result of the blocking function
    static func background<T>(_ service: ServiceTypes, wrapErrors: Bool = true, _ blocking: @escaping () throws -> T,
                              functionName: String = #function) async throws -> T
    {
        let startTime = CFAbsoluteTimeGetCurrent()
        let backgroundTime = requestBackgroundTime(for: service, functionName: functionName)
        let result = try await withCheckedThrowingContinuation { continuation in
            service.queue.async {
                defer { backgroundTime?.end() }
                do {
                    let res = try blocking()
                    continuation.resume(with: .success(res))
                } catch {
                    continuation.resume(throwing: queueError(from: error, service: service, wrapErrors: wrapErrors))
                }
            }
        }

        let timeElapsed = Double(round(100 * (CFAbsoluteTimeGetCurrent() - startTime)) / 100)
        Logger.performance("\(functionName) took \(timeElapsed) seconds on \(service) queue")

        return result
    }

    /// Executes an async function on chosen service queue
    /// - Parameters:
    ///   - service: Quese to run on
    ///   - execute: The function
    ///   - functionName: The name of the function for logging
    /// - Returns: The result of the async function
    static func background<T>(_ service: ServiceTypes, wrapErrors: Bool = true, _ execute: @escaping () async throws -> T,
                              functionName: String = #function) async throws -> T
    {
        let startTime = CFAbsoluteTimeGetCurrent()

        let backgroundTime = requestBackgroundTime(for: service, functionName: functionName)
        return try await withCheckedThrowingContinuation { continuation in
            service.queue.async {
                Task {
                    defer { backgroundTime?.end() }
                    do {
                        let result = try await execute()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: queueError(from: error, service: service, wrapErrors: wrapErrors))
                    }

                    let timeElapsed = Double(round(100 * (CFAbsoluteTimeGetCurrent() - startTime)) / 100)
                    Logger.performance("\(functionName) took \(timeElapsed) seconds on \(service) queue")
                }
            }
        }
    }

    private static func queueError(from error: Error, service: ServiceTypes, wrapErrors: Bool) -> Error {
        guard wrapErrors else {
            Logger.error(error.localizedDescription, context: "ServiceQueue: \(service)")
            return error
        }

        let appError = AppError(error: error)
        Logger.error("\(appError.message) [\(appError.debugMessage ?? "")]", context: "ServiceQueue: \(service)")
        return appError
    }

    /// Executes a function on chosen service queue with completion handler
    /// - Parameters:
    ///   - service: Queue to run on
    ///   - execute: The function to execute
    ///   - functionName: The name of the function for logging
    ///   - completion: Completion handler called with result or error
    static func background<T>(
        _ service: ServiceTypes, _ execute: @escaping () throws -> T, functionName: String = #function,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()

        let backgroundTime = requestBackgroundTime(for: service, functionName: functionName)
        service.queue.async {
            defer { backgroundTime?.end() }
            do {
                let result = try execute()
                let timeElapsed = Double(round(100 * (CFAbsoluteTimeGetCurrent() - startTime)) / 100)
                Logger.performance("\(functionName) took \(timeElapsed) seconds on \(service) queue")
                completion(.success(result))
            } catch {
                let appError = AppError(error: error)
                Logger.error("\(appError.message) [\(appError.debugMessage ?? "")]", context: "ServiceQueue: \(service)")
                completion(.failure(appError))
            }
        }
    }

    /// Executes an async function on chosen service queue with completion handler
    /// - Parameters:
    ///   - service: Queue to run on
    ///   - execute: The async function to execute
    ///   - functionName: The name of the function for logging
    ///   - completion: Completion handler called with result or error
    static func background<T>(
        _ service: ServiceTypes, _ execute: @escaping () async throws -> T, functionName: String = #function,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()

        let backgroundTime = requestBackgroundTime(for: service, functionName: functionName)
        service.queue.async {
            Task {
                defer { backgroundTime?.end() }
                do {
                    let result = try await execute()
                    let timeElapsed = Double(round(100 * (CFAbsoluteTimeGetCurrent() - startTime)) / 100)
                    Logger.performance("\(functionName) took \(timeElapsed) seconds on \(service) queue")
                    completion(.success(result))
                } catch {
                    let appError = AppError(error: error)
                    Logger.error("\(appError.message) [\(appError.debugMessage ?? "")]", context: "ServiceQueue: \(service)")
                    completion(.failure(appError))
                }
            }
        }
    }
}

/// Asks iOS for background running time until `end()` is called, the instance is released or the time expires.
/// Its state is guarded by `lock`.
final class BackgroundTime: @unchecked Sendable {
    typealias Begin = (_ name: String, _ expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    typealias End = (UIBackgroundTaskIdentifier) -> Void

    private let lock = NSLock()
    private let endTask: End
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    init(name: String, begin: Begin? = nil, end: End? = nil) {
        let begin = begin ?? BackgroundTime.beginTask
        let end = end ?? BackgroundTime.endTask
        endTask = end
        let identifier = begin(name) { [weak self] in
            self?.end()
        }
        // The expiration handler can run before the identifier is stored.
        let endedAlready = lock.withLock {
            if !ended {
                self.identifier = identifier
            }
            return ended
        }
        if endedAlready, identifier != .invalid {
            end(identifier)
        }
    }

    deinit {
        end()
    }

    func end() {
        let identifier = lock.withLock {
            ended = true
            defer { self.identifier = .invalid }
            return self.identifier
        }
        if identifier != .invalid {
            endTask(identifier)
        }
    }

    /// Runs `body` with background running time, for database work outside `ServiceQueue`'s database queues.
    static func during<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let backgroundTime = BackgroundTime(name: name)
        defer { backgroundTime.end() }
        return try await body()
    }

    /// Runs `body` with background running time, for database work outside `ServiceQueue`'s database queues.
    static func during<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let backgroundTime = BackgroundTime(name: name)
        defer { backgroundTime.end() }
        return try body()
    }

    /// The app sets these at launch. The notification extension, which compiles this file too, has no `UIApplication`, so its
    /// work runs without background time.
    nonisolated(unsafe) static var beginTask: Begin = { _, _ in .invalid }
    nonisolated(unsafe) static var endTask: End = { _ in }
}
