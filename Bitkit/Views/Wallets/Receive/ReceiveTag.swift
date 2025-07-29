import SwiftUI

struct ReceiveTag: View {
    @Binding var navigationPath: [ReceiveRoute]
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var activityListViewModel: ActivityListViewModel

    @State private var newTag: String = ""
    @State private var isLoading: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("wallet__tags_add"), showBackButton: true)

            let tagsToShow = activityListViewModel.recentlyUsedTags

            if !tagsToShow.isEmpty {
                CaptionMText(localizedString("wallet__tags_previously"))
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

            CaptionMText(localizedString("wallet__tags_new"))
                .padding(.top, 28)
                .padding(.bottom, 8)

            TextField(localizedString("wallet__tags_new_enter"), text: $newTag, backgroundColor: .white06)
                .focused($isTextFieldFocused)
                .disabled(isLoading)
                .autocapitalization(.none)
                .autocorrectionDisabled(true)
                .submitLabel(.done)

            Spacer()

            CustomButton(
                title: localizedString("wallet__tags_add_button"),
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
            // try await activityListViewModel.appendTag(toActivity: activityId, tags: [tag])
            navigationPath.removeLast()
        } catch {
            app.toast(type: .error, title: "Failed to add tag", description: error.localizedDescription)
        }
        isLoading = false
    }
}
