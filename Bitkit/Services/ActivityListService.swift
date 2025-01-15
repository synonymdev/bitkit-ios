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
            let activities = try getActivities(filter: .all, txType: nil, tags: nil, search: nil, minDate: nil, maxDate: nil, limit: nil, sortDirection: nil)
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
                    txType: payment.direction == .outbound ? .sent : .received,
                    status: state,
                    value: UInt64(payment.amountSats ?? 0),
                    fee: nil, // TODO:
                    invoice: "lnbc123",
                    message: "",
                    timestamp: UInt64(payment.latestUpdateTimestamp),
                    preimage: nil,
                    createdAt: UInt64(payment.latestUpdateTimestamp),
                    updatedAt: UInt64(payment.latestUpdateTimestamp)
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
    
    func get(
        filter: ActivityFilter? = nil,
        txType: PaymentType? = nil,
        tags: [String]? = nil,
        search: String? = nil,
        minDate: UInt64? = nil,
        maxDate: UInt64? = nil,
        limit: UInt32? = nil,
        sortDirection: SortDirection? = nil
    ) async throws -> [Activity] {
        try await ServiceQueue.background(.activity) {
            try getActivities(
                filter: filter,
                txType: txType,
                tags: tags,
                search: search,
                minDate: minDate,
                maxDate: maxDate,
                limit: limit,
                sortDirection: sortDirection
            )
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
    
    func getAllUniqueTags() async throws -> [String] {
        try await ServiceQueue.background(.activity) {
            try Bitkit.getAllUniqueTags()
        }
    }
    
    #if DEBUG
    func generateRandomTestData(count: Int = 100) async throws {
        try await ServiceQueue.background(.activity) {
            let timestamp = UInt64(Date().timeIntervalSince1970)
            let possibleTags = ["coffee", "food", "shopping", "transport", "entertainment", "work", "friends", "family"]
            let possibleMessages = [
                "Coffee at Starbucks",
                "Lunch with friends",
                "Uber ride",
                "Movie tickets",
                "Groceries",
                "Work payment",
                "Gift for mom",
                "Split dinner bill",
                "Monthly rent",
                "Gym membership"
            ]
            
            for i in 0..<count {
                let isLightning = Bool.random()
                let value = UInt64.random(in: 1000...1000000) // Random sats between 1k and 1M
                let timestamp = timestamp - UInt64.random(in: 0...2592000) // Random time in last 30 days
                let txType: PaymentType = Bool.random() ? .sent : .received
                let status: PaymentState = {
                    let random = Int.random(in: 0...10)
                    if random < 8 { return .succeeded } // 80% chance
                    if random < 9 { return .pending } // 10% chance
                    return .failed // 10% chance
                }()
                
                let activity: Activity
                let id: String
                
                if isLightning {
                    id = "test-lightning-\(i)"
                    activity = .lightning(LightningActivity(
                        id: id,
                        txType: txType,
                        status: status,
                        value: value,
                        fee: UInt64.random(in: 1...1000),
                        invoice: "lnbc\(value)",
                        message: possibleMessages.randomElement() ?? "",
                        timestamp: timestamp,
                        preimage: Bool.random() ? "preimage\(i)" : nil,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    ))
                } else {
                    id = "test-onchain-\(i)"
                    activity = .onchain(OnchainActivity(
                        id: id,
                        txType: txType,
                        txId: String(repeating: "a", count: 64), // Mock txid
                        value: value,
                        fee: UInt64.random(in: 100...10000),
                        feeRate: UInt64.random(in: 1...100),
                        address: "bc1...\(i)",
                        confirmed: Bool.random(),
                        timestamp: timestamp,
                        isBoosted: Bool.random(),
                        isTransfer: Bool.random(),
                        doesExist: true,
                        confirmTimestamp: Bool.random() ? timestamp + 3600 : nil, // 1 hour later if confirmed
                        channelId: Bool.random() ? "channel\(i)" : nil,
                        transferTxId: nil,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    ))
                }
                
                // Insert activity
                try insertActivity(activity: activity)
                
                // Add random tags (0-3 tags)
                let numTags = Int.random(in: 0...3)
                if numTags > 0 {
                    let tags = Array(Set((0..<numTags).map { _ in possibleTags.randomElement()! }))
                    try await self.addTags(toActivity: id, tags)
                }
            }
        }
    }
    #endif
}
