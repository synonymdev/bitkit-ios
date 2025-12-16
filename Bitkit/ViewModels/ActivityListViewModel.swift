import BitkitCore
import Combine
import SwiftUI

enum ActivityTab: CaseIterable, CustomStringConvertible {
    case all, sent, received, other, paykit

    var description: String {
        switch self {
        case .all:
            return t("wallet__activity_tabs__all")
        case .sent:
            return t("wallet__activity_tabs__sent")
        case .received:
            return t("wallet__activity_tabs__received")
        case .other:
            return t("wallet__activity_tabs__other")
        case .paykit:
            return "Paykit"
        }
    }
}

/// Unified activity item that can represent either a standard Activity or a Paykit receipt
public enum UnifiedActivityItem: Identifiable, Hashable {
    case standard(Activity)
    case paykit(PaymentReceipt)
    
    public var id: String {
        switch self {
        case .standard(let activity):
            return activity.id
        case .paykit(let receipt):
            return "paykit-\(receipt.id)"
        }
    }
    
    public var timestamp: UInt64 {
        switch self {
        case .standard(let activity):
            switch activity {
            case .lightning(let ln): return ln.timestamp
            case .onchain(let on): return on.timestamp
            }
        case .paykit(let receipt):
            return UInt64(receipt.createdAt.timeIntervalSince1970)
        }
    }
    
    public var isSent: Bool {
        switch self {
        case .standard(let activity):
            switch activity {
            case .lightning(let ln): return ln.txType == .sent
            case .onchain(let on): return on.txType == .sent
            }
        case .paykit(let receipt):
            return receipt.direction == .sent
        }
    }
    
    public var isReceived: Bool {
        switch self {
        case .standard(let activity):
            switch activity {
            case .lightning(let ln): return ln.txType == .received
            case .onchain(let on): return on.txType == .received
            }
        case .paykit(let receipt):
            return receipt.direction == .received
        }
    }
    
    public var isPaykit: Bool {
        if case .paykit = self { return true }
        return false
    }
}

@MainActor
class ActivityListViewModel: ObservableObject {
    @Published var filteredActivities: [Activity]? = nil
    @Published var lightningActivities: [Activity]? = nil
    @Published var onchainActivities: [Activity]? = nil
    @Published var searchText: String = ""
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var selectedTags: Set<String> = []
    @Published var selectedTab: ActivityTab = .all

    // Latest activities for home screen
    @Published var latestActivities: [Activity]? = nil

    // Grouped activities for display
    @Published var groupedActivities: [ActivityGroupItem] = []
    
    // MARK: - Paykit Integration
    
    /// Paykit payment receipts
    @Published var paykitReceipts: [PaymentReceipt] = []
    
    /// Unified activities combining standard activities and Paykit receipts
    @Published var unifiedActivities: [UnifiedActivityItem] = []
    
    /// Grouped unified activities for display
    @Published var groupedUnifiedActivities: [UnifiedActivityGroupItem] = []
    
    /// Show Paykit receipts in activity list
    @Published var showPaykitReceipts: Bool = true
    
    private let receiptStorage: ReceiptStorage

    private let coreService: CoreService
    private let lightningService: LightningService
    private let transferService: TransferService
    private var searchCancellable: AnyCancellable?
    private var dateRangeCancellable: AnyCancellable?
    private var tagsCancellable: AnyCancellable?
    private var tabCancellable: AnyCancellable?
    private var activitiesChangedCancellable: AnyCancellable?

    @Published private(set) var availableTags: [String] = []
    @Published private(set) var feeEstimates: FeeRates? = nil

    private func updateAvailableTags() async {
        do {
            availableTags = try await coreService.activity.allPossibleTags()
        } catch {
            Logger.error(error, context: "Failed to get available tags")
            availableTags = []
        }
    }

    private func updateFeeEstimates() async {
        do {
            feeEstimates = try await coreService.blocktank.fees(refresh: false)
        } catch {
            Logger.error("Failed to load fee estimates: \(error)", context: "ActivityListViewModel")
            feeEstimates = nil
        }
    }

    init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared,
        transferService: TransferService,
        receiptStorage: ReceiptStorage = ReceiptStorage()
    ) {
        self.coreService = coreService
        self.lightningService = lightningService
        self.transferService = transferService
        self.receiptStorage = receiptStorage

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

        // Setup tab subscription
        tabCancellable =
            $selectedTab
                .sink { [weak self] _ in
                    Task { [weak self] in
                        await self?.updateFilteredActivities()
                    }
                }

        activitiesChangedCancellable = coreService.activity.activitiesChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.syncState()
                }
            }

        Task {
            await syncState()
        }
    }

    /// Convenience initializer for testing and previews
    convenience init(
        coreService: CoreService = .shared,
        lightningService: LightningService = .shared
    ) {
        let transferService = TransferService(
            lightningService: lightningService,
            blocktankService: coreService.blocktank
        )
        self.init(
            coreService: coreService,
            lightningService: lightningService,
            transferService: transferService
        )
    }

    func syncState() async {
        do {
            // Get latest activities first as that's displayed on the home view
            let limitLatest: UInt32 = 3
            // Fetch extra to account for potential filtering of replaced transactions
            let latest = try await coreService.activity.get(filter: .all, limit: limitLatest * 3)
            let filtered = await filterOutReplacedSentTransactions(latest)
            latestActivities = Array(filtered.prefix(Int(limitLatest)))

            // Fetch all activities
            await updateFilteredActivities()

            let lightningActivities = try await coreService.activity.get(filter: .lightning)

            let onchain = try await coreService.activity.get(filter: .onchain)
            onchainActivities = await filterOutReplacedSentTransactions(onchain)

            // Sync Paykit receipts
            syncPaykitReceipts()

            // Update available tags and fee estimates
            await updateAvailableTags()
            await updateFeeEstimates()
            
            // Update unified activities
            updateUnifiedActivities()
        } catch {
            Logger.error(error, context: "Failed to sync activities")
        }
    }
    
    // MARK: - Paykit Receipt Methods
    
    /// Sync Paykit receipts from storage
    private func syncPaykitReceipts() {
        paykitReceipts = receiptStorage.listReceipts()
    }
    
    /// Update unified activities combining standard and Paykit
    private func updateUnifiedActivities() {
        var unified: [UnifiedActivityItem] = []
        
        // Add standard activities
        if let activities = filteredActivities {
            unified.append(contentsOf: activities.map { .standard($0) })
        }
        
        // Add Paykit receipts if enabled
        if showPaykitReceipts {
            // Filter Paykit receipts based on selected tab
            let filteredReceipts: [PaymentReceipt]
            switch selectedTab {
            case .all:
                filteredReceipts = paykitReceipts
            case .sent:
                filteredReceipts = paykitReceipts.filter { $0.direction == .sent }
            case .received:
                filteredReceipts = paykitReceipts.filter { $0.direction == .received }
            case .paykit:
                filteredReceipts = paykitReceipts
            case .other:
                filteredReceipts = []
            }
            unified.append(contentsOf: filteredReceipts.map { .paykit($0) })
        }
        
        // Sort by timestamp (newest first)
        unified.sort { $0.timestamp > $1.timestamp }
        
        unifiedActivities = unified
        
        // Update grouped unified activities
        groupedUnifiedActivities = groupUnifiedActivities(unified)
    }
    
    /// Group unified activities by date
    func groupUnifiedActivities(_ activities: [UnifiedActivityItem]) -> [UnifiedActivityGroupItem] {
        let calendar = Calendar.current
        let now = Date()

        // Calculate date boundaries
        let beginningOfDay = calendar.startOfDay(for: now)
        let beginningOfYesterday = calendar.date(byAdding: .day, value: -1, to: beginningOfDay)!
        let beginningOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let beginningOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let beginningOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

        // Group activities
        var today: [UnifiedActivityItem] = []
        var yesterday: [UnifiedActivityItem] = []
        var thisWeek: [UnifiedActivityItem] = []
        var thisMonth: [UnifiedActivityItem] = []
        var thisYear: [UnifiedActivityItem] = []
        var earlier: [UnifiedActivityItem] = []

        for activity in activities {
            let activityDate = Date(timeIntervalSince1970: TimeInterval(activity.timestamp))

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

        // Build result array
        var result: [UnifiedActivityGroupItem] = []

        if !today.isEmpty {
            let headerDate = Date(timeIntervalSince1970: TimeInterval(today.first?.timestamp ?? 0))
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: today.map { .activity($0) })
        }

        if !yesterday.isEmpty {
            let headerDate = Date(timeIntervalSince1970: TimeInterval(yesterday.first?.timestamp ?? 0))
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: yesterday.map { .activity($0) })
        }

        if !thisWeek.isEmpty {
            let headerDate = Date(timeIntervalSince1970: TimeInterval(thisWeek.first?.timestamp ?? 0))
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisWeek.map { .activity($0) })
        }

        if !thisMonth.isEmpty {
            let headerDate = Date(timeIntervalSince1970: TimeInterval(thisMonth.first?.timestamp ?? 0))
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisMonth.map { .activity($0) })
        }

        if !thisYear.isEmpty {
            let headerDate = Date(timeIntervalSince1970: TimeInterval(thisYear.first?.timestamp ?? 0))
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisYear.map { .activity($0) })
        }

        if !earlier.isEmpty {
            let headerDate = Date(timeIntervalSince1970: TimeInterval(earlier.first?.timestamp ?? 0))
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: earlier.map { .activity($0) })
        }

        return result
    }
    
    /// Get a Paykit receipt by ID
    func getPaykitReceipt(id: String) -> PaymentReceipt? {
        paykitReceipts.first { $0.id == id }
    }
    
    /// Toggle showing Paykit receipts
    func togglePaykitReceipts() {
        showPaykitReceipts.toggle()
        updateUnifiedActivities()
    }

    func clearDateRange() {
        startDate = nil
        endDate = nil
    }

    func clearTags() {
        selectedTags.removeAll()
    }

    func resetFilters() {
        searchText = ""
        startDate = nil
        endDate = nil
        selectedTags.removeAll()
        selectedTab = .all
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

            // Apply base filtering
            let baseFilteredActivities = try await coreService.activity.get(
                filter: .all,
                tags: selectedTags.isEmpty ? nil : Array(selectedTags),
                search: searchText.isEmpty ? nil : searchText,
                minDate: minDate,
                maxDate: maxDate
            )

            // Filter out replaced sent transactions that appear in another transaction's boostTxIds
            let filteredOutReplaced = await filterOutReplacedSentTransactions(baseFilteredActivities)

            // Apply tab filtering
            filteredActivities = filterActivitiesByTab(filteredOutReplaced, selectedTab: selectedTab)

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

                // This ensures pending transfers are marked as settled when channels become ready
                do {
                    try await transferService.syncTransferStates()
                    Logger.debug("Transfer states synced after LDK payments sync", context: "ActivityListViewModel")
                } catch {
                    Logger.error("Failed to sync transfer states after LDK payments sync", context: error.localizedDescription)
                    // Don't throw - we don't want to fail the entire sync if transfer sync fails
                }

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

    /// Find activity by payment hash or transaction ID
    func findActivity(byPaymentId paymentId: String) async throws -> Activity {
        guard !paymentId.isEmpty else {
            throw AppError(message: "Payment ID is empty", debugMessage: nil)
        }

        let activities = try await coreService.activity.get(filter: .all, limit: 50)
        let activity = activities.first { activity in
            switch activity {
            case let .lightning(ln):
                return ln.id == paymentId
            case let .onchain(on):
                return on.txId == paymentId
            }
        }

        guard let activity else {
            throw AppError(
                message: "Activity not found",
                debugMessage: "Could not find activity for payment ID: \(paymentId)"
            )
        }

        return activity
    }

    func getAllPossibleTags() async throws -> [String] {
        try await coreService.activity.allPossibleTags()
    }

    func appendTags(toActivity activityId: String, tags: [String]) async throws {
        try await coreService.activity.appendTags(toActivity: activityId, tags)
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

    // MARK: - Boost Methods

    func boost(activityId: String, feeRate: UInt32) async throws -> String {
        do {
            let txid = try await coreService.activity.boostOnchainTransaction(activityId: activityId, feeRate: feeRate)
            // Refresh the activities after boosting
            await syncState()
            return txid
        } catch {
            Logger.error(error, context: "Failed to boost activity \(activityId)")
            throw error
        }
    }
}

// MARK: - Activity Grouping

enum ActivityGroupItem: Hashable {
    case header(String)
    case activity(Activity)
}

/// Unified activity group item for mixed activity lists
enum UnifiedActivityGroupItem: Hashable {
    case header(String)
    case activity(UnifiedActivityItem)
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
            let timestamp: UInt64 = switch activity {
            case let .lightning(ln):
                ln.timestamp
            case let .onchain(on):
                on.timestamp
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
                    let timestamp: UInt64 = switch activity {
                    case let .lightning(ln): ln.timestamp
                    case let .onchain(on): on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? now
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: today.map { .activity($0) })
        }

        if !yesterday.isEmpty {
            let headerDate =
                yesterday.first.map { activity in
                    let timestamp: UInt64 = switch activity {
                    case let .lightning(ln): ln.timestamp
                    case let .onchain(on): on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfYesterday
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: yesterday.map { .activity($0) })
        }

        if !thisWeek.isEmpty {
            let headerDate =
                thisWeek.first.map { activity in
                    let timestamp: UInt64 = switch activity {
                    case let .lightning(ln): ln.timestamp
                    case let .onchain(on): on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfWeek
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisWeek.map { .activity($0) })
        }

        if !thisMonth.isEmpty {
            let headerDate =
                thisMonth.first.map { activity in
                    let timestamp: UInt64 = switch activity {
                    case let .lightning(ln): ln.timestamp
                    case let .onchain(on): on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfMonth
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisMonth.map { .activity($0) })
        }

        if !thisYear.isEmpty {
            let headerDate =
                thisYear.first.map { activity in
                    let timestamp: UInt64 = switch activity {
                    case let .lightning(ln): ln.timestamp
                    case let .onchain(on): on.timestamp
                    }
                    return Date(timeIntervalSince1970: TimeInterval(timestamp))
                } ?? beginningOfYear
            result.append(.header(DateFormatterHelpers.getActivityGroupHeader(for: headerDate)))
            result.append(contentsOf: thisYear.map { .activity($0) })
        }

        if !earlier.isEmpty {
            let headerDate =
                earlier.first.map { activity in
                    let timestamp: UInt64 = switch activity {
                    case let .lightning(ln): ln.timestamp
                    case let .onchain(on): on.timestamp
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

    /// Filter out replaced sent transactions that appear in another transaction's boostTxIds
    private func filterOutReplacedSentTransactions(_ activities: [Activity]) async -> [Activity] {
        // Get cached set of txIds that appear in boostTxIds
        let txIdsInBoostTxIds = await coreService.activity.getTxIdsInBoostTxIds()

        // Filter out activities that:
        // 1. Are onchain
        // 2. Have doesExist = false
        // 3. Are sent transactions
        // 4. Appear in another transaction's boostTxIds
        return activities.filter { activity in
            if case let .onchain(onchain) = activity {
                if !onchain.doesExist && onchain.txType == .sent && txIdsInBoostTxIds.contains(onchain.txId) {
                    return false
                }
            }
            return true
        }
    }

    /// Filter activities based on the selected tab
    private func filterActivitiesByTab(_ activities: [Activity], selectedTab: ActivityTab) -> [Activity] {
        switch selectedTab {
        case .all:
            return activities
        case .sent:
            return activities.filter { activity in
                switch activity {
                case let .lightning(ln):
                    return ln.txType == .sent
                case let .onchain(on):
                    return on.txType == .sent && !on.isTransfer
                }
            }
        case .received:
            return activities.filter { activity in
                switch activity {
                case let .lightning(ln):
                    return ln.txType == .received
                case let .onchain(on):
                    return on.txType == .received && !on.isTransfer
                }
            }
        case .other:
            return activities.filter { activity in
                switch activity {
                case .lightning:
                    return false // Lightning activities are never transfers
                case let .onchain(on):
                    return on.isTransfer
                }
            }
        }
    }
}
