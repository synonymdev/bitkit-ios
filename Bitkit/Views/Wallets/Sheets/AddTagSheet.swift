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
    @EnvironmentObject private var activityListViewModel: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var tagManager: TagManager

    let config: AddTagSheetItem

    @State private var newTag: String = ""
    @State private var isLoading: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        Sheet(id: .addTag) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("wallet__tags_add"))

                PreviouslyUsedTagsView { tag in
                    await appendTagAndClose(tag)
                }

                TagInputForm(
                    tagText: $newTag,
                    isTextFieldFocused: $isTextFieldFocused,
                    isLoading: isLoading,
                    textFieldTestId: "TagInput",
                    buttonTestId: "ActivityTagsSubmit"
                ) { tag in
                    await appendTagAndClose(tag)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func appendTagAndClose(_ tag: String) async {
        guard !tag.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            tagManager.addToLastUsedTags(tag)
            try await activityListViewModel.appendTags(toActivity: config.activityId, tags: [tag])
            sheets.hideSheet()
        } catch {
            app.toast(type: .error, title: "Failed to add tag", description: error.localizedDescription)
        }
    }
}
