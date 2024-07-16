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
    private static let bdkQueue = DispatchQueue(label: "bdk-queue", qos: .utility)
    
    private init() {}
    
    enum ServiceTypes {
        case ldk
        case bdk
        
        var queue: DispatchQueue {
            switch self {
            case .ldk:
                return ServiceQueue.ldkQueue
            case .bdk:
                return ServiceQueue.bdkQueue
            }
        }
    }
    
    static func background<T>(_ service: ServiceTypes, _ blocking: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            service.queue.async {
                do {
                    let res = try blocking()
                    continuation.resume(with: .success(res))
                } catch {
                    let appError = AppError(error: error)
                    print("Service Error: \(appError.message) (\(appError.debugMessage ?? ""))")
                    continuation.resume(throwing: appError)
                }
            }
        }
    }
}
