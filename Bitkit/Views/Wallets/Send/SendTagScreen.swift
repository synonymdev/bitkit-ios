import SwiftUI

struct SendTagScreen: View {
    @EnvironmentObject var tagManager: TagManager
    @Environment(\.dismiss) private var dismiss

    @Binding var navigationPath: [SendRoute]
    @State private var newTagText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__tags_add"), showBackButton: true)

            PreviouslyUsedTagsView { tag in
                await addTag(tag)
            }

            TagInputForm(
                tagText: $newTagText,
                isTextFieldFocused: $isTextFieldFocused
            ) { tag in
                await addTag(tag)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addTag(_ tag: String) async {
        tagManager.addTagToSelection(tag)
        dismiss()
    }
}
