import SwiftUI

struct TagsListView: View {
    let tags: [String]
    var icon: TagIconType?
    var onTagPress: ((String) -> Void)?
    var onTagDelete: ((String) -> Void)?
    var title: String?
    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0

    var body: some View {
        if !tags.isEmpty || title != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    CaptionMText(title)
                        .padding(.top, topPadding)
                        .padding(.bottom, tags.isEmpty ? max(bottomPadding, 8) : 16)
                }

                if !tags.isEmpty {
                    WrappingHStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Tag(
                                tag,
                                icon: icon ?? .close,
                                onPress: onTagPress.map { action in { action(tag) } },
                                onDelete: onTagDelete.map { action in { action(tag) } }
                            )
                        }
                    }
                    .padding(.bottom, bottomPadding)
                }
            }
        }
    }
}
