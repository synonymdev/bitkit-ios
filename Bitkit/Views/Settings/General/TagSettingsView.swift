import SwiftUI

struct TagSettingsView: View {
    @EnvironmentObject var activityViewModel: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(t("settings__general__tags_previously"))
                    .textCase(.uppercase)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WrappingHStack(spacing: 8) {
                    ForEach(activityViewModel.recentlyUsedTags, id: \.self) { tag in
                        Tag(
                            tag,
                            icon: .trash,
                            onDelete: {
                                activityViewModel.removeFromRecentlyUsedTags(tag)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(t("settings__general__tags"))
        .task {
            await activityViewModel.syncState()
        }
    }
}

#Preview {
    NavigationStack {
        TagSettingsView()
            .environmentObject(ActivityListViewModel())
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
