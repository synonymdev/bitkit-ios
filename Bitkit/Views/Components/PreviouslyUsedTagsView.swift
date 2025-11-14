import SwiftUI

struct PreviouslyUsedTagsView: View {
    @EnvironmentObject var tagManager: TagManager
    let onTagPress: (String) async -> Void

    var body: some View {
        TagsListView(
            tags: tagManager.lastUsedTags,
            onTagPress: { tag in
                Task { await onTagPress(tag) }
            },
            title: tagManager.lastUsedTags.isEmpty ? nil : t("wallet__tags_previously"),
            bottomPadding: 28
        )
    }
}
