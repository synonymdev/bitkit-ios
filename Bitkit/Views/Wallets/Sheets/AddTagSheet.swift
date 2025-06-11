import SwiftUI

struct AddTagConfig {
    let activityId: String
}

struct AddTagSheetItem: SheetItem, Equatable {
    let id: SheetID = .addTag
    let size: SheetSize = .small
    let activityId: String

    init(activityId: String) {
        self.activityId = activityId
    }

    static func == (lhs: AddTagSheetItem, rhs: AddTagSheetItem) -> Bool {
        return lhs.activityId == rhs.activityId
    }
}

struct AddTagSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var activityListViewModel: ActivityListViewModel
    let config: AddTagSheetItem
    var previewTags: [String]? = nil

    private var activityId: String {
        config.activityId
    }

    @State private var newTag: String = ""
    @State private var isLoading: Bool = false

    var body: some View {
        Sheet(id: .addTag) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: localizedString("wallet__tags_add"))

                let tagsToShow = previewTags ?? activityListViewModel.recentlyUsedTags

                if !tagsToShow.isEmpty {
                    CaptionText(localizedString("wallet__tags_previously"))
                        .textCase(.uppercase)
                        .padding(.bottom, 16)

                    WrappingHStack(spacing: 8) {
                        ForEach(tagsToShow, id: \.self) { tag in
                            Tag(
                                tag,
                                onPress: {
                                    Task { await appendTagAndClose(tag) }
                                }
                            )
                        }
                    }
                }

                Spacer()

                CaptionText(localizedString("wallet__tags_new"))
                    .textCase(.uppercase)
                    .padding(.top, 28)
                    .padding(.bottom, 8)

                TextField(localizedString("wallet__tags_new_enter"), text: $newTag)
                    .disabled(isLoading)
                    .padding(.top, 8)

                CustomButton(
                    title: localizedString("wallet__tags_add_button"),
                    isDisabled: newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isLoading: isLoading
                ) {
                    Task {
                        await appendTagAndClose(newTag.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal)
        }
    }

    private func appendTagAndClose(_ tag: String) async {
        guard !tag.isEmpty else { return }
        isLoading = true
        do {
            try await activityListViewModel.appendTag(toActivity: activityId, tags: [tag])
            sheets.hideSheet()
        } catch {
            app.toast(type: .error, title: "Failed to add tag", description: error.localizedDescription)
        }
        isLoading = false
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                AddTagSheet(
                    config: AddTagSheetItem(activityId: "test-activity-id"),
                    previewTags: ["Lunch", "Mom", "Dad", "Conference", "Dinner", "Tip", "Friend", "Gift"]
                )
                .environmentObject(AppViewModel())
                .environmentObject(SheetViewModel())
                .environmentObject(ActivityListViewModel())
                .presentationDetents([.height(400)])
            }
        )
        .preferredColorScheme(.dark)
}
