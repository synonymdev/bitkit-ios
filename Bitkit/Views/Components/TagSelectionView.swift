import SwiftUI

struct TagSelectionView: View {
    @EnvironmentObject var tagManager: TagManager
    let onDelete: (String) -> Void
    let onAddTag: () -> Void
    var buttonTestId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TagsListView(
                tags: tagManager.selectedTagsArray,
                icon: .close,
                onTagDelete: onDelete,
                title: t("wallet__tags"),
                topPadding: 16,
                bottomPadding: 12
            )

            CustomButton(
                title: t("wallet__tags_add"),
                size: .small,
                icon: Image("tag").foregroundColor(.brandAccent)
            ) {
                onAddTag()
            }
            .accessibilityIdentifierIfPresent(buttonTestId)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
