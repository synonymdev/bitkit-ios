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

                if !tagManager.lastUsedTags.isEmpty {
                    CaptionMText(t("wallet__tags_previously"))
                        .padding(.bottom, 16)

                    WrappingHStack(spacing: 8) {
                        ForEach(tagManager.lastUsedTags, id: \.self) { tag in
                            Tag(
                                tag,
                                onPress: {
                                    Task { await appendTagAndClose(tag) }
                                }
                            )
                        }
                    }
                    .padding(.bottom, 28)
                }

                CaptionMText(t("wallet__tags_new"))
                    .padding(.bottom, 8)

                TextField(t("wallet__tags_new_enter"), text: $newTag, backgroundColor: .white08)
                    .focused($isTextFieldFocused)
                    .disabled(isLoading)
                    .padding(.top, 8)

                Spacer()

                CustomButton(
                    title: t("wallet__tags_add_button"),
                    isDisabled: newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isLoading: isLoading
                ) {
                    Task {
                        await appendTagAndClose(newTag.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                .buttonBottomPadding(isFocused: isTextFieldFocused)
            }
            .padding(.horizontal)
        }
    }

    private func appendTagAndClose(_ tag: String) async {
        guard !tag.isEmpty else { return }
        isLoading = true
        do {
            tagManager.addToLastUsedTags(tag)
            try await activityListViewModel.appendTags(toActivity: config.activityId, tags: [tag])
            sheets.hideSheet()
        } catch {
            app.toast(type: .error, title: "Failed to add tag", description: error.localizedDescription)
        }
        isLoading = false
    }
}
