import SwiftUI

// MARK: - Widget

/// In-app Bitcoin Blocks widget (v61). Renders the wide layout — used inside the home feed
/// and the wide carousel page on the preview screen.
struct BlocksWidget: View {
    var options: BlocksWidgetOptions = .init()
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = BlocksViewModel.shared

    init(
        options: BlocksWidgetOptions = BlocksWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .blocks,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            content
        }
        .task {
            viewModel.startUpdates()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.blockData == nil {
            WidgetContentBuilder.loadingView()
        } else if viewModel.error != nil && viewModel.blockData == nil {
            WidgetContentBuilder.errorView(t("widgets__blocks__error"))
        } else if let data = viewModel.blockData {
            BlocksWidgetWideContent(data: data, options: options)
        }
    }
}

#Preview {
    BlocksWidget()
        .padding()
        .background(.black)
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
