import SwiftUI

struct TagSettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var tagManager: TagManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(t("settings__general__tags_previously"))
                    .textCase(.uppercase)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WrappingHStack(spacing: 8) {
                    ForEach(tagManager.lastUsedTags, id: \.self) { tag in
                        Tag(
                            tag,
                            icon: .trash,
                            onDelete: {
                                tagManager.removeFromLastUsedTags(tag)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(t("settings__general__tags"))
    }
}
