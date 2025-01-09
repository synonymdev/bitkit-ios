//
//  ActivityListViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/17.
//

import SwiftUI
import Combine

@MainActor
class ActivityListViewModel: ObservableObject {
    static let shared = ActivityListViewModel()
    
    @Published var filteredActivities: [Activity]? = nil
    @Published var lightningActivities: [Activity]? = nil
    @Published var onchainActivities: [Activity]? = nil
    @Published var searchText: String = ""
    
    // Latest activities for home screen
    @Published var latestActivities: [Activity]? = nil
    @Published var latestLightningActivities: [Activity]? = nil
    @Published var latestOnchainActivities: [Activity]? = nil
    
    private let activityService: ActivityListService
    private let lightningService: LightningService
    private var searchCancellable: AnyCancellable?
    
    init(activityService: ActivityListService = .shared,
         lightningService: LightningService = .shared)
    {
        self.activityService = activityService
        self.lightningService = lightningService
        
        // Setup search text subscription with debounce
        searchCancellable = $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.updateFilteredActivities()
                }
            }
        
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
            await updateFilteredActivities()
            lightningActivities = try await activityService.get(filter: .lightning)
            onchainActivities = try await activityService.get(filter: .onchain)
            
        } catch {
            Logger.error(error, context: "Failed to sync activities")
        }
    }
    
    // Any change to searchText, tags or dates will trigger this
    private func updateFilteredActivities() async {
        do {
            filteredActivities = try await activityService.get(
                filter: .all,
                search: searchText.isEmpty ? nil : searchText
            )
        } catch {
            Logger.error(error, context: "Failed to filter activities")
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
