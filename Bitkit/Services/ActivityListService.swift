//
//  ActivityListService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/17.
//

import Foundation
import LDKNode

class ActivityListService {
    static let shared = ActivityListService()
    private let walletIndex: Int
    
    private init(walletIndex: Int = 0) {
        self.walletIndex = walletIndex

        Task {
            do {
                try await initializeDatabase()
            } catch {
                Logger.error(error)
            }
        }
    }
    
    private func initializeDatabase() async throws {
        let dbPath = Env.bitkitCoreStorage(walletIndex: walletIndex).path
        try await ServiceQueue.background(.activity) {
            _ = try initDb(basePath: dbPath)
        }
    }
    
    // MARK: - Database Management
    
    func removeAll() async throws {
        try await ServiceQueue.background(.activity) {
            // Only allow removing on regtest for now
            guard Env.network == .regtest else {
                throw AppError(message: "Regtest only", debugMessage: nil)
            }
            
            // Get all activities and delete them one by one
            let activities = try getAllActivities(limit: nil)
            for activity in activities {
                let id: String
                switch activity {
                case .lightning(let ln): id = ln.id
                case .onchain(let on): id = on.id
                }
                
                _ = try deleteActivityById(activityId: id)
            }
        }
    }
    
    // MARK: - Activity Methods
    
    func insert(_ activity: Activity) async throws {
        try await ServiceQueue.background(.activity) {
            try insertActivity(activity: activity)
        }
    }
    
    // TODO: insert based on LDK node event
    // TODO: insert based on LDK node payment type
    
    func syncLdkNodePayments(_ payments: [PaymentDetails]) async throws {
        try await ServiceQueue.background(.activity) {
            var addedCount = 0
            var updatedCount = 0
            
            for payment in payments {
                // Skip pending inbound payments, just means they created an invoice
                guard !(payment.status == .pending && payment.direction == .inbound) else { continue }
                
                let state: PaymentState
                switch payment.status {
                case .failed:
                    state = .failed
                case .pending:
                    state = .pending
                case .succeeded:
                    state = .succeeded
                }
                
                let ln = LightningActivity(
                    id: payment.id,
                    activityType: .lightning,
                    txType: payment.direction == .outbound ? .sent : .received,
                    status: state,
                    value: Int64(payment.amountSats ?? 0),
                    fee: nil, // TODO:
                    invoice: "lnbc123",
                    message: "",
                    timestamp: Int64(payment.latestUpdateTimestamp),
                    preimage: nil,
                    createdAt: Int64(payment.latestUpdateTimestamp),
                    updatedAt: Int64(payment.latestUpdateTimestamp)
                )
                
                if let _ = try getActivityById(activityId: payment.id) {
                    try updateActivity(activityId: payment.id, activity: .lightning(ln))
                    updatedCount += 1
                } else {
                    try insertActivity(activity: .lightning(ln))
                    addedCount += 1
                }

                // TODO: handle onchain activity when it comes in ldk-node
            }
            
            Logger.info("Synced LDK payments - Added: \(addedCount), Updated: \(updatedCount)", context: "ActivityListService")
        }
    }
    
    func getActivity(id: String) async throws -> Activity? {
        try await ServiceQueue.background(.activity) {
            try getActivityById(activityId: id)
        }
    }
    
    func all(limit: UInt32? = nil) async throws -> [Activity] {
        try await ServiceQueue.background(.activity) {
            try getAllActivities(limit: limit)
        }
    }
    
    func lightning(limit: UInt32? = nil) async throws -> [Activity] {
        try await ServiceQueue.background(.activity) {
            try getAllLightningActivities(limit: limit).map { Activity.lightning($0) }
        }
    }
    
    func onchain(limit: UInt32? = nil) async throws -> [Activity] {
        try await ServiceQueue.background(.activity) {
            try getAllOnchainActivities(limit: limit).map { Activity.onchain($0) }
        }
    }
    
    func update(id: String, activity: Activity) async throws {
        try await ServiceQueue.background(.activity) {
            try updateActivity(activityId: id, activity: activity)
        }
    }
    
    func delete(id: String) async throws -> Bool {
        try await ServiceQueue.background(.activity) {
            try deleteActivityById(activityId: id)
        }
    }
    
    // MARK: - Tag Methods
    
    func addTags(toActivity id: String, _ tags: [String]) async throws {
        try await ServiceQueue.background(.activity) {
            try Bitkit.addTags(activityId: id, tags: tags)
        }
    }
    
    func removeTags(fromActivity id: String, _ tags: [String]) async throws {
        try await ServiceQueue.background(.activity) {
            try Bitkit.removeTags(activityId: id, tags: tags)
        }
    }
    
    func getTags(forActivity id: String) async throws -> [String] {
        try await ServiceQueue.background(.activity) {
            try Bitkit.getTags(activityId: id)
        }
    }
    
    func getActivities(withTag tag: String, limit: UInt32? = nil) async throws -> [Activity] {
        try await ServiceQueue.background(.activity) {
            try getActivitiesByTag(tag: tag, limit: limit)
        }
    }
}
