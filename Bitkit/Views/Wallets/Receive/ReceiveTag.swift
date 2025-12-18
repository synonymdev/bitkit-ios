import BitkitCore
import SwiftUI

struct ReceiveTag: View {
    @Binding var navigationPath: [ReceiveRoute]
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var newTag: String = ""
    @State private var isLoading: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__tags_add"), showBackButton: true)

            PreviouslyUsedTagsView { tag in
                await appendTagAndClose(tag)
            }

            TagInputForm(
                tagText: $newTag,
                isTextFieldFocused: $isTextFieldFocused,
                isLoading: isLoading,
                textFieldTestId: "TagInputReceive",
                buttonTestId: "ReceiveTagsSubmit"
            ) { tag in
                await appendTagAndClose(tag)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func appendTagAndClose(_ tag: String) async {
        guard !tag.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            guard let paymentId = await wallet.paymentId(), !paymentId.isEmpty else {
                app.toast(type: .error, title: t("wallet__tags_add_error_header"), description: t("wallet__tags_add_error_no_payment_id"))
                return
            }

            try await CoreService.shared.activity.addPreActivityMetadataTags(
                paymentId: paymentId,
                tags: [tag]
            )

            tagManager.addTagToSelection(tag)

            await MainActor.run {
                newTag = ""
                navigationPath.removeLast()
            }
        } catch {
            app.toast(type: .error, title: t("wallet__tags_add_error_header"), description: error.localizedDescription)
        }
    }
}
