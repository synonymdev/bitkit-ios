import SwiftUI

struct SendTagScreen: View {
    @EnvironmentObject var activityListViewModel: ActivityListViewModel
    @EnvironmentObject var tagManager: TagManager
    @Environment(\.dismiss) private var dismiss

    @Binding var navigationPath: [SendRoute]
    @State private var newTagText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var trimmedTagText: String {
        newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__tags_add"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                let tagsToShow = tagManager.lastUsedTags

                if !tagsToShow.isEmpty {
                    CaptionMText(t("wallet__tags_previously"))
                        .padding(.bottom, 16)

                    WrappingHStack(spacing: 8) {
                        ForEach(tagsToShow, id: \.self) { tag in
                            Tag(tag, onPress: {
                                addTag(tag)
                            })
                        }
                    }
                }

                CaptionMText(t("wallet__tags_new"))
                    .padding(.top, 28)
                    .padding(.bottom, 8)

                TextField(t("wallet__tags_new_enter"), text: $newTagText, backgroundColor: .white08)
                    .focused($isTextFieldFocused)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)

                Spacer()

                CustomButton(
                    title: t("wallet__tags_add_button"),
                    isDisabled: trimmedTagText.isEmpty,
                ) {
                    addTag(trimmedTagText)
                }
                .padding(.bottom, isTextFieldFocused ? 16 : 0)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func addTag(_ tag: String) {
        tagManager.addTagToSelection(tag)
        dismiss()
    }
}
