import SwiftUI

struct PreviouslyUsedTagsView: View {
    let tags: [String]
    let onTagPress: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            CaptionMText(t("wallet__tags_previously"))

            TagsListView(
                tags: tags,
                onTagPress: { tag in
                    Task { await onTagPress(tag) }
                }
            )
        }
    }
}
