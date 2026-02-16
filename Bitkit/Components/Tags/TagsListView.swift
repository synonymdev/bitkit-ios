import SwiftUI

struct TagsListView: View {
    let tags: [String]
    var icon: TagIconType?
    var onAddTag: (() -> Void)?
    var onTagPress: ((String) -> Void)?
    var onTagDelete: ((String) -> Void)?
    var addButtonTestId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WrappingHStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Tag(
                        tag,
                        icon: icon ?? .close,
                        onPress: onTagPress.map { action in { action(tag) } },
                        onDelete: onTagDelete.map { action in { action(tag) } }
                    )
                }

                if let onAddTag {
                    AddTagButton(onPress: onAddTag)
                        .accessibilityIdentifierIfPresent(addButtonTestId ?? "TagsAdd")
                }
            }
        }
    }
}
