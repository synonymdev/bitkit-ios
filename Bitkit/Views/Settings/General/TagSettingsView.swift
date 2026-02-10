import SwiftUI

struct TagSettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var tagManager: TagManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__tags"))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("settings__general__tags_previously"))
                        .padding(.top, 24)
                        .padding(.bottom, 16)

                    TagsListView(
                        tags: tagManager.lastUsedTags,
                        icon: .trash,
                        onTagDelete: { tag in
                            tagManager.removeFromLastUsedTags(tag)
                        }
                    )
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}
