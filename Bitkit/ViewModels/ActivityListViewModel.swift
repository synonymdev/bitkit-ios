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
    @Published var filteredActivities: [Activity]? = nil
    @Published var lightningActivities: [Activity]? = nil
    @Published var onchainActivities: [Activity]? = nil
    @Published var searchText: String = ""
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var selectedTags: Set<String> = []

    // Latest activities for home screen
    @Published var latestActivities: [Activity]? = nil

    // Grouped activities for display
    @Published var groupedActivities: [ActivityGroupItem] = []

    private let coreService: CoreService
    private let lightningService: LightningService
    private var searchCancellable: AnyCancellable?
    private var dateRangeCancellable: AnyCancellable?
    private var tagsCancellable: AnyCancellable?

    @Published private(set) var availableTags: [String] = []
    @Published private(set) var recentlyUsedTags: [String] = []

    // Persistent storage for recently used tags
    @AppStorage("recentlyUsedTags") private var recentlyUsedTagsData: Data = Data()

    private func updateAvailableTags() async {
        do {
            availableTags = try await coreService.activity.allPossibleTags()
        } catch {
            Logger.error(error, context: "Failed to get available tags")
            availableTags = []
        }
    }

    private func addToRecentlyUsedTags(_ tag: String) {
        // Remove the tag if it already exists
        recentlyUsedTags.removeAll { $0 == tag }
        // Add to the front of the list
        recentlyUsedTags.insert(tag, at: 0)
        // Keep only the most recent 20 tags to prevent unlimited growth
        if recentlyUsedTags.count > 20 {
            recentlyUsedTags = Array(recentlyUsedTags.prefix(20))
        }

        // Persist to storage
        saveRecentlyUsedTags()
    }

    private func loadRecentlyUsedTags() {
        do {
            let tags = try JSONDecoder().decode([String].self, from: recentlyUsedTagsData)
            recentlyUsedTags = tags
        } catch {
            // If no saved data or decode fails, start with empty array
            recentlyUsedTags = []
        }
    }

    private func saveRecentlyUsedTags() {
        do {
            recentlyUsedTagsData = try JSONEncoder().encode(recentlyUsedTags)
        } catch {
            Logger.error(error, context: "Failed to persist recently used tags")
        }
    }

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared
    ) {
        self.coreService = coreService
        self.lightningService = lightningService

        // Load persisted recently used tags
        loadRecentlyUsedTags()

        // Setup search text subscription with debounce
        searchCancellable =
            $searchText
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
        tagsCancellable =
            $selectedTags
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
            // Get latest activities first as that's displayed on the home view
            let limitLatest: UInt32 = 3
            latestActivities = try await coreService.activity.get(filter: .all, limit: limitLatest)

            // Fetch all activities
            await updateFilteredActivities()
            lightningActivities = try await coreService.activity.get(filter: .lightning)
            onchainActivities = try await coreService.activity.get(filter: .onchain)

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

            filteredActivities = try await coreService.activity.get(
                filter: .all,
                tags: selectedTags.isEmpty ? nil : Array(selectedTags),
                search: searchText.isEmpty ? nil : searchText,
                minDate: minDate,
                maxDate: maxDate
            )

            // Update grouped activities
            updateGroupedActivities()
        } catch {
            Logger.error(error, context: "Failed to filter activities")
        }
    }

    private var isSyncingLdkNodePayments: Bool = false
    func syncLdkNodePayments() async throws {
        guard !isSyncingLdkNodePayments else {
            Logger.warn("LDK node payments are already being synced, skipping")
            return
        }

        if let ldkPayments = lightningService.payments {
            isSyncingLdkNodePayments = true
            do {
                try await coreService.activity.syncLdkNodePayments(ldkPayments)
                await syncState()
                isSyncingLdkNodePayments = false
            } catch {
                isSyncingLdkNodePayments = false
                throw error
            }
        }
    }

    // MARK: - Tag Methods

    func getActivities(withTag tag: String) async throws -> [Activity] {
        try await coreService.activity.get(tags: [tag])
    }

    func getAllPossibleTags() async throws -> [String] {
        try await coreService.activity.allPossibleTags()
    }

    func appendTag(toActivity activityId: String, tags: [String]) async throws {
        try await coreService.activity.appendTag(toActivity: activityId, tags)
        // Add tags to recently used list
        for tag in tags {
            addToRecentlyUsedTags(tag)
        }
        // Refresh the activities after adding a tag
        await syncState()
    }

    func removeTag(fromActivity activityId: String, tag: String) async throws {
        try await coreService.activity.dropTags(fromActivity: activityId, [tag])
        // Refresh the activities after removing a tag
        await syncState()
    }

    func getTagsForActivity(_ activityId: String) async throws -> [String] {
        try await coreService.activity.tags(forActivity: activityId)
    }

    func removeFromRecentlyUsedTags(_ tag: String) {
        recentlyUsedTags.removeAll { $0 == tag }
        saveRecentlyUsedTags()
    }
}

// MARK: - Activity Grouping

enum ActivityGroupItem: Hashable {
    case header(String)
    case activity(Activity)
}

extension ActivityListViewModel {
    func groupActivities(_ activities: [Activity]) -> [ActivityGroupItem] {
        let calendar = Calendar.current
        let now = Date()

        // Calculate date boundaries
        let beginningOfDay = calendar.startOfDay(for: now)
        let beginningOfYesterday = calendar.date(byAdding: .day, value: -1, to: beginningOfDay)!
        let beginningOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let beginningOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let beginningOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

        // Group activities
        var today: [Activity] = []
        var yesterday: [Activity] = []
        var thisWeek: [Activity] = []
        var thisMonth: [Activity] = []
        var thisYear: [Activity] = []
        var earlier: [Activity] = []

        for activity in activities {
            let timestamp: UInt64
            switch activity {
            case .lightning(let ln):
                timestamp = ln.timestamp
            case .onchain(let on):
                timestamp = on.timestamp
            }

            let activityDate = Date(timeIntervalSince1970: TimeInterval(timestamp))

            if activityDate >= beginningOfDay {
                today.append(activity)
            } else if activityDate >= beginningOfYesterday {
                yesterday.append(activity)
            } else if activityDate >= beginningOfWeek {
                thisWeek.append(activity)
            } else if activityDate >= beginningOfMonth {
                thisMonth.append(activity)
            } else if activityDate >= beginningOfYear {
                thisYear.append(activity)
            } else {
                earlier.append(activity)
            }
        }

        // Build result array using localized headers
        var result: [ActivityGroupItem] = []

        if !today.isEmpty {
            let headerDate =
                today.first.map { activity in
                    let timestamp: UInt64
                    switch activity {
                    case .lightning(let ln): timestamp = ln.timestamp
                    case .onchain(let on): timestamp = on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? now
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: today.map { .activity($0) })
        }

        if !yesterday.isEmpty {
            let headerDate =
                yesterday.first.map { activity in
                    let timestamp: UInt64
                    switch activity {
                    case .lightning(let ln): timestamp = ln.timestamp
                    case .onchain(let on): timestamp = on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfYesterday
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: yesterday.map { .activity($0) })
        }

        if !thisWeek.isEmpty {
            let headerDate =
                thisWeek.first.map { activity in
                    let timestamp: UInt64
                    switch activity {
                    case .lightning(let ln): timestamp = ln.timestamp
                    case .onchain(let on): timestamp = on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfWeek
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisWeek.map { .activity($0) })
        }

        if !thisMonth.isEmpty {
            let headerDate =
                thisMonth.first.map { activity in
                    let timestamp: UInt64
                    switch activity {
                    case .lightning(let ln): timestamp = ln.timestamp
                    case .onchain(let on): timestamp = on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfMonth
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisMonth.map { .activity($0) })
        }

        if !thisYear.isEmpty {
            let headerDate =
                thisYear.first.map { activity in
                    let timestamp: UInt64
                    switch activity {
                    case .lightning(let ln): timestamp = ln.timestamp
                    case .onchain(let on): timestamp = on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfYear
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisYear.map { .activity($0) })
        }

        if !earlier.isEmpty {
            let headerDate =
                earlier.first.map { activity in
                    let timestamp: UInt64
                    switch activity {
                    case .lightning(let ln): timestamp = ln.timestamp
                    case .onchain(let on): timestamp = on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? Date.distantPast
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: earlier.map { .activity($0) })
        }

        return result
    }

    private func updateGroupedActivities() {
        if let activities = filteredActivities {
            groupedActivities = groupActivities(activities)
        } else {
            groupedActivities = []
        }
    }
}
