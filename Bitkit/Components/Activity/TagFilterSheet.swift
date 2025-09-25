import SwiftUI

struct TagFilterSheetItem: SheetItem {
    let id: SheetID = .tagFilter
    let size: SheetSize = .small
}

struct TagFilterSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var tagManager: TagManager
    @ObservedObject var viewModel: ActivityListViewModel
    @Binding var isPresented: Bool

    var body: some View {
        Sheet(id: .tagFilter, data: TagFilterSheetItem()) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("wallet__tags_filter_title"))

                CaptionMText(t("wallet__tags_filter"))
                    .padding(.bottom, 16)

                if tagManager.lastUsedTags.isEmpty {
                    BodySText(t("wallet__tags_no"), textColor: .textPrimary)
                } else {
                    WrappingHStack(spacing: 8) {
                        ForEach(tagManager.lastUsedTags, id: \.self) { tag in
                            Tag(tag, icon: .close, onPress: {
                                if viewModel.selectedTags.contains(tag) {
                                    viewModel.selectedTags.remove(tag)
                                } else {
                                    viewModel.selectedTags.insert(tag)
                                }

                                isPresented = false
                            })
                        }
                    }
                }

                Spacer()
            }
            .navigationBarHidden(true)
            .padding(.horizontal, 16)
            .sheetBackground()
        }
    }
}
