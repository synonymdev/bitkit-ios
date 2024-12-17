//
//  ActivityListService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/17.
//

import Foundation

class ActivityListService {
    static let shared = ActivityListService()
    private let walletIndex: Int
    
    private init(walletIndex: Int = 0) { // Default to first wallet like LightningService
        self.walletIndex = walletIndex
        // Initialize database on first access
        Task {
            try? await initializeDatabase()
        }
    }
    
    private func initializeDatabase() async throws {
        let dbPath = Env.bitkitCoreStorage(walletIndex: walletIndex).path
        try await ServiceQueue.background(.activity) {
            _ = try initDb(basePath: dbPath)
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
    
    func lightning(limit: UInt32? = nil) async throws -> [LightningActivity] {
        try await ServiceQueue.background(.activity) {
            try getAllLightningActivities(limit: limit)
        }
    }
    
    func onchain(limit: UInt32? = nil) async throws -> [OnchainActivity] {
        try await ServiceQueue.background(.activity) {
            try getAllOnchainActivities(limit: limit)
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
