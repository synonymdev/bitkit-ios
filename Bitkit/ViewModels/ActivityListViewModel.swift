//
//  ActivityListViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/17.
//

import Combine
import SwiftUI

@MainActor
class ActivityListViewModel: ObservableObject {
    static let shared = ActivityListViewModel()
    
    @Published var filteredActivities: [Activity]? = nil
    @Published var lightningActivities: [Activity]? = nil
    @Published var onchainActivities: [Activity]? = nil
    @Published var searchText: String = ""
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var selectedTags: Set<String> = []
    
    // Latest activities for home screen
    @Published var latestActivities: [Activity]? = nil
    @Published var latestLightningActivities: [Activity]? = nil
    @Published var latestOnchainActivities: [Activity]? = nil
    
    private let activityService: ActivityListService
    private let lightningService: LightningService
    private var searchCancellable: AnyCancellable?
    private var dateRangeCancellable: AnyCancellable?
    private var tagsCancellable: AnyCancellable?
    
    // Get all unique tags from all activities
    func getAvailableTags() async -> [String] {
        var tags = Set<String>()
        do {
            // Get all activities without any filters
            let allActivities = try await activityService.get(filter: .all)
            for activity in allActivities {
                let id: String
                switch activity {
                case .lightning(let ln): id = ln.id
                case .onchain(let on): id = on.id
                }
                
                if let activityTags = try? await activityService.getTags(forActivity: id) {
                    tags.formUnion(activityTags)
                }
            }
        } catch {
            Logger.error(error, context: "Failed to get available tags")
        }
        return Array(tags).sorted()
    }
    
    @Published private(set) var availableTags: [String] = []
    
    private func updateAvailableTags() async {
        availableTags = await getAvailableTags()
    }
    
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
        
        // Setup date range subscription
        dateRangeCancellable = Publishers.CombineLatest($startDate, $endDate)
            .sink { [weak self] _, _ in
                Task { [weak self] in
                    await self?.updateFilteredActivities()
                }
            }
        
        // Setup tags subscription
        tagsCancellable = $selectedTags
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
            
            // Update available tags
            await updateAvailableTags()
        } catch {
            Logger.error(error, context: "Failed to sync activities")
        }
    }
    
    func clearDateRange() {
        startDate = nil
        endDate = nil
    }
    
    func clearTags() {
        selectedTags.removeAll()
    }
    
    private func updateFilteredActivities() async {
        do {
            // Convert dates to timestamps if they exist, ensuring start date is start of day and end date is end of day
            let minDate = startDate.map {
                let startOfDay = Calendar.current.startOfDay(for: $0)
                return UInt64(startOfDay.timeIntervalSince1970)
            }
            
            let maxDate = endDate.map {
                let nextDay = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0)
                return UInt64(nextDay.timeIntervalSince1970 - 1)
            }
            
            filteredActivities = try await activityService.get(
                filter: .all,
                tags: selectedTags.isEmpty ? nil : Array(selectedTags),
                search: searchText.isEmpty ? nil : searchText,
                minDate: minDate,
                maxDate: maxDate
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
