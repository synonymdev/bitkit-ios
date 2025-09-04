import Combine
import Foundation

@MainActor
final class TagManager: ObservableObject {
    @Published private(set) var selectedTags: Set<String> = []
    @Published private(set) var lastUsedTags: [String] = []

    private let userDefaultsKey = "lastUsedTags"
    private let maxLastUsedTags = 10

    init() {
        loadLastUsedTags()
    }

    // MARK: - Tag Selection Management

    /// Add a tag to the current selection (for send/receive tags)
    func addTagToSelection(_ tag: String) {
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return }

        selectedTags.insert(trimmedTag)
        addToLastUsedTags(trimmedTag)
    }

    /// Remove a tag from the current selection
    func removeTagFromSelection(_ tag: String) {
        selectedTags.remove(tag)
    }

    /// Clear all selected tags
    func clearSelectedTags() {
        selectedTags.removeAll()
    }

    /// Get current selected tags as array
    var selectedTagsArray: [String] {
        return Array(selectedTags).sorted()
    }

    /// Add a tag to the last used tags list
    func addToLastUsedTags(_ tag: String) {
        var tags = lastUsedTags

        // Remove if already exists (to move to front)
        tags.removeAll { $0.lowercased() == tag.lowercased() }

        // Add to beginning
        tags.insert(tag, at: 0)

        // Limit to maxLastUsedTags
        tags = Array(tags.prefix(maxLastUsedTags))

        lastUsedTags = tags
        saveLastUsedTags()
    }

    /// Remove a tag from the recently used tags list
    func removeFromLastUsedTags(_ tag: String) {
        lastUsedTags.removeAll { $0.lowercased() == tag.lowercased() }
        saveLastUsedTags()
    }

    /// Load last used tags from UserDefaults
    private func loadLastUsedTags() {
        lastUsedTags = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
    }

    /// Save last used tags to UserDefaults
    private func saveLastUsedTags() {
        UserDefaults.standard.set(lastUsedTags, forKey: userDefaultsKey)
    }
}
