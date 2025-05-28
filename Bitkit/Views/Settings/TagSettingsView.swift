import SwiftUI

struct TagSettingsView: View {
    @EnvironmentObject var activityViewModel: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !activityViewModel.availableTags.isEmpty {
                    CaptionText(NSLocalizedString("settings__general__tags_previously", comment: ""))
                        .textCase(.uppercase)
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    WrappingHStack(spacing: 8) {
                        ForEach(activityViewModel.availableTags, id: \.self) { tag in
                            Tag(
                                tag,
                                icon: .trash,
                                onDelete: {
                                    Task {
                                        await deleteTag(tag)
                                    }
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

    private func deleteTag(_ tag: String) async {
        do {
            try await activityViewModel.deleteTagGlobally(tag)
        } catch {
            app.toast(
                type: .error,
                title: NSLocalizedString("settings__tags__delete_error_title", comment: ""),
                description: error.localizedDescription
            )
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
