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
        
        Task {
            await syncState()
        }
    }
    
    func syncState() async {
        do {
            // Get latest activities first as that's displayed on the initial views
            let limitLatest: UInt32 = 3
            latestActivities = try await activityService.get(filter: .all, limit: limitLatest)
            latestLightningActivities = try await activityService.get(filter: .lightning, limit: limitLatest)
            latestOnchainActivities = try await activityService.get(filter: .onchain, limit: limitLatest)

            // Fetch all activities
            allActivities = try await activityService.get(filter: .all)
            lightningActivities = try await activityService.get(filter: .lightning)
            onchainActivities = try await activityService.get(filter: .onchain)
            
        } catch {
            Logger.error(error, context: "Failed to sync activities")
        }
    }
    
    func syncLdkNodePayments() async throws {
        if let ldkPayments = lightningService.payments {
            try await activityService.syncLdkNodePayments(ldkPayments)
            await syncState()
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
        try await activityService.get(tags: [tag])
    }
}
