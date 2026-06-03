import SwiftUI

// MARK: - Widget

/// In-app Bitcoin Blocks widget (v61). Renders the wide layout — used inside the home feed
/// and the wide carousel page on the preview screen.
struct BlocksWidget: View {
    var options: BlocksWidgetOptions = .init()
    var size: WidgetSize = .wide
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = BlocksViewModel.shared

    init(
        options: BlocksWidgetOptions = BlocksWidgetOptions(),
        size: WidgetSize = .wide,
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.size = size
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .blocks,
            size: size,
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
            if size == .small {
                BlocksWidgetCompactContent(data: data, options: options)
            } else {
                BlocksWidgetWideContent(data: data, options: options)
                    .frame(height: BlocksWidgetWideContent.inAppContentHeight)
            }
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
