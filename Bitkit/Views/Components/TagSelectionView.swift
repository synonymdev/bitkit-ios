import SwiftUI

struct TagSelectionView: View {
    @EnvironmentObject var tagManager: TagManager
    @Binding var navigationPath: [SendRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(t("wallet__tags"))
                .padding(.bottom, 8)

            if !tagManager.selectedTags.isEmpty {
                WrappingHStack(spacing: 8) {
                    ForEach(tagManager.selectedTagsArray, id: \.self) { tag in
                        Tag(tag, icon: .close, onDelete: {
                            tagManager.removeTagFromSelection(tag)
                        })
                    }
                }
                .padding(.bottom, 8)
            }

            CustomButton(
                title: t("wallet__tags_add"),
                size: .small,
                icon: Image("tag").foregroundColor(.brandAccent)
            ) {
                navigationPath.append(.tag)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
