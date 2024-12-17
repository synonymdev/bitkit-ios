//
//  ActivityListViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/17.
//

import SwiftUI

@MainActor
class ActivityListViewModel: ObservableObject {
    static let shared = ActivityListViewModel()
    
    @Published var allActivities: [Activity]? = nil
    @Published var lightningActivities: [Activity]? = nil
    @Published var onchainActivities: [Activity]? = nil
    
    // Latest activities for home screen
    @Published var latestActivities: [Activity]? = nil
    @Published var latestLightningActivities: [Activity]? = nil
    @Published var latestOnchainActivities: [Activity]? = nil
    
    private let activityService: ActivityListService
    private let lightningService: LightningService
    
    init(activityService: ActivityListService = .shared,
         lightningService: LightningService = .shared)
    {
        self.activityService = activityService
        self.lightningService = lightningService
    }
    
    func syncState() async {
        do {
            if let ldkPayments = lightningService.payments {
                try await activityService.syncLdkNodePayments(ldkPayments)
            }

            // Fetch all activities
            allActivities = try await activityService.all()
            lightningActivities = try await activityService.lightning()
            onchainActivities = try await activityService.onchain()
            
            // Get latest activities for each type (limit 3)
            let limitLatest: UInt32 = 3
            latestActivities = try await activityService.all(limit: limitLatest)
            latestLightningActivities = try await activityService.lightning(limit: limitLatest)
            latestOnchainActivities = try await activityService.onchain(limit: limitLatest)
        } catch {
            Logger.error(error, context: "Failed to sync activities")
        }
    }
    
    // MARK: - Tag Methods
    
    func addTags(_ tags: [String], toActivity id: String) async throws {
        try await activityService.addTags(toActivity: id, tags)
        await syncState() // Refresh UI after adding tags
    }
    
    func removeTags(_ tags: [String], fromActivity id: String) async throws {
        try await activityService.removeTags(fromActivity: id, tags)
        await syncState() // Refresh UI after removing tags
    }
    
    func getActivities(withTag tag: String) async throws -> [Activity] {
        try await activityService.getActivities(withTag: tag)
    }
}
