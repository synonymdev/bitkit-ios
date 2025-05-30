import SwiftUI

struct TagSettingsView: View {
    @EnvironmentObject var activityViewModel: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !activityViewModel.recentlyUsedTags.isEmpty {
                    CaptionText(NSLocalizedString("settings__general__tags_previously", comment: ""))
                        .textCase(.uppercase)
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        .padding(.horizontal, 16)
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
                    .padding(.horizontal, 16)
                } else {
                    CaptionText(NSLocalizedString("wallet__tags_no", comment: ""))
                        .textCase(.uppercase)
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings__general__tags", comment: ""))
        .navigationBarTitleDisplayMode(.large)
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
