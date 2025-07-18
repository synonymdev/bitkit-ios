import SwiftUI
import BitkitCore

@MainActor
class ActivityItemViewModel: ObservableObject {
    private let coreService: CoreService = .shared

    @Published private(set) var activity: Activity
    @Published private(set) var tags: [String] = []
    @Published private(set) var activityId: String

    init(item: Activity) {
        self.activity = item
        self.activityId = {
            switch item {
            case .lightning(let activity):
                return activity.id
            case .onchain(let activity):
                return activity.id
            }
        }()
        Task {
            await loadTags()
        }
    }

    func loadTags() async {
        do {
            tags = try await coreService.activity.tags(forActivity: activityId)
        } catch {
            Logger.error(error, context: "Failed to load tags for activity \(activityId)")
            tags = []
        }
    }

    func removeTag(_ tag: String) async {
        do {
            try await coreService.activity.dropTags(fromActivity: activityId, [tag])
            await loadTags() // Reload tags after removal
        } catch {
            Logger.error(error, context: "Failed to remove tag \(tag) from activity \(activityId)")
        }
    }

    func refreshActivity() async {
        do {
            if let updatedActivity = try await coreService.activity.getActivity(id: activityId) {
                activity = updatedActivity
            } else {
                // Activity not found by ID - it might have been replaced by RBF
                // Try to find a replacement activity by txId for onchain activities
                if case .onchain(let onchainActivity) = activity {
                    Logger.debug("Activity \(activityId) not found, looking for RBF replacement", context: "ActivityItemViewModel.refreshActivity")
                    
                    // Try multiple times with delay to allow sync to complete
                    for attempt in 1...3 {
                        Logger.debug("Attempt \(attempt) to find RBF replacement", context: "ActivityItemViewModel.refreshActivity")
                        
                        // Get all recent activities to find potential replacement
                        let recentActivities = try await coreService.activity.get(filter: .onchain, limit: 50)
                        
                        // Look for a boosted transaction that could be our replacement
                        for recentActivity in recentActivities {
                            if case .onchain(let recentOnchain) = recentActivity {
                                // Check if this is a boosted transaction with same value and type
                                if recentOnchain.isBoosted && 
                                   recentOnchain.txType == onchainActivity.txType &&
                                   recentOnchain.value == onchainActivity.value &&
                                   recentOnchain.timestamp >= onchainActivity.timestamp {
                                    Logger.info("Found RBF replacement activity: \(recentOnchain.id)", context: "ActivityItemViewModel.refreshActivity")
                                    activity = recentActivity
                                    activityId = recentOnchain.id
                                    await loadTags()
                                    return
                                }
                            }
                        }
                        
                        // If not found and not the last attempt, wait and try again
                        if attempt < 3 {
                            Logger.debug("RBF replacement not found on attempt \(attempt), waiting 2 seconds", context: "ActivityItemViewModel.refreshActivity")
                            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
                        }
                    }
                    Logger.warn("No RBF replacement found for activity \(activityId) after 3 attempts", context: "ActivityItemViewModel.refreshActivity")
                }
            }
        } catch {
            Logger.error(error, context: "Failed to refresh activity \(activityId)")
        }
    }
}
