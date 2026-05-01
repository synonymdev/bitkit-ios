import SwiftUI

struct TagSettingsView: View {
    @EnvironmentObject var tagManager: TagManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__tags"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader(t("settings__general__tags_previously"))

                    TagsListView(
                        tags: tagManager.lastUsedTags,
                        icon: .trash,
                        onTagDelete: { tag in
                            tagManager.removeFromLastUsedTags(tag)
                        }
                    )
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
    }
}
