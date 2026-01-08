import Combine
import SwiftUI

@MainActor
final class SuggestionsManager: ObservableObject {
    @Published private(set) var dismissedIds: Set<String> = []

    private let userDefaultsKey = "dismissedSuggestions"

    init() {
        reloadDismissed()
    }

    func dismiss(_ suggestionId: String) {
        dismissedIds.insert(suggestionId)
        saveDismissed()
    }

    func resetDismissed() {
        dismissedIds.removeAll()
        saveDismissed()
    }

    func isDismissed(_ suggestionId: String) -> Bool {
        dismissedIds.contains(suggestionId)
    }

    func reloadDismissed() {
        let dismissedArray = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        dismissedIds = Set(dismissedArray)
    }

    private func saveDismissed() {
        let dismissedArray = Array(dismissedIds)
        UserDefaults.standard.set(dismissedArray, forKey: userDefaultsKey)
    }
}
