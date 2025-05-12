import SwiftUI

@MainActor
class ActivityItemViewModel: ObservableObject {
    private let item: Activity
    private let coreService: CoreService = .shared

    @Published private(set) var tags: [String] = []
    @Published private(set) var activityId: String

    init(item: Activity) {
        self.item = item
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
}
