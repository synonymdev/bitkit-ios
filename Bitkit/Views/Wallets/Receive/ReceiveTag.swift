import SwiftUI

struct ReceiveTag: View {
    @Binding var navigationPath: [ReceiveRoute]
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var tagManager: TagManager

    @State private var newTag: String = ""
    @State private var isLoading: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__tags_add"), showBackButton: true)

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
            }

            CaptionMText(t("wallet__tags_new"))
                .padding(.top, 28)
                .padding(.bottom, 8)

            TextField(t("wallet__tags_new_enter"), text: $newTag, backgroundColor: .white06)
                .focused($isTextFieldFocused)
                .disabled(isLoading)
                .autocapitalization(.none)
                .autocorrectionDisabled(true)
                .submitLabel(.done)

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
            .padding(.bottom, isTextFieldFocused ? 16 : 0)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func appendTagAndClose(_ tag: String) async {
        guard !tag.isEmpty else { return }
        isLoading = true
        do {
            navigationPath.removeLast()
        } catch {
            app.toast(type: .error, title: "Failed to add tag", description: error.localizedDescription)
        }
        isLoading = false
    }
}
