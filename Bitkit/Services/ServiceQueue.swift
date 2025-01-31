//
//  ServiceQueue.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/04.
//

import Foundation

/// Handles app services each on it's own dedicated queue
class ServiceQueue {
    private static let ldkQueue = DispatchQueue(label: "ldk-queue", qos: .utility)
    private static let coreQueue = DispatchQueue(label: "core-queue", qos: .utility)
    private static let migrationQueue = DispatchQueue(label: "migration-queue", qos: .utility)
    private static let forexQueue = DispatchQueue(label: "forex-queue", qos: .utility)

    private init() {}
    
    enum ServiceTypes {
        case ldk
        case core
        case migration
        case forex
        
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
            }
        }
    }
    
    /// Executes a thread blocking function on chosen service queue
    /// - Parameters:
    ///   - service: Queue to run on
    ///   - blocking: The function to run
    ///   - functionName: The name of the function for logging
    /// - Returns: The result of the blocking function
    static func background<T>(_ service: ServiceTypes, _ blocking: @escaping () throws -> T, functionName: String = #function) async throws -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await withCheckedThrowingContinuation { continuation in
            service.queue.async {
                do {
                    let res = try blocking()
                    continuation.resume(with: .success(res))
                } catch {
                    let appError = AppError(error: error)
                    Logger.error("\(appError.message) [\(appError.debugMessage ?? "")]", context: "ServiceQueue: \(service)")
                    continuation.resume(throwing: appError)
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
    static func background<T>(_ service: ServiceTypes, _ execute: @escaping () async throws -> T, functionName: String = #function) async throws -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        return try await withCheckedThrowingContinuation { continuation in
            service.queue.async {
                Task {
                    do {
                        let result = try await execute()
                        continuation.resume(returning: result)
                    } catch {
                        let appError = AppError(error: error)
                        Logger.error("\(appError.message) [\(appError.debugMessage ?? "")]", context: "ServiceQueue: \(service)")
                        continuation.resume(throwing: appError)
                    }
                    
                    let timeElapsed = Double(round(100 * (CFAbsoluteTimeGetCurrent() - startTime)) / 100)
                    Logger.performance("\(functionName) took \(timeElapsed) seconds on \(service) queue")
                }
            }
        }
    }
}
