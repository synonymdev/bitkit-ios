import SwiftUI

/// A widget that displays Bitcoin block information
struct BlocksWidget: View {
    /// Configuration options for the widget
    var options: BlocksWidgetOptions = .init()

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// View model for handling block data
    @StateObject private var viewModel = BlocksViewModel.shared

    /// Initialize the widget
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
            VStack(spacing: 0) {
                if viewModel.isLoading {
                    WidgetContentBuilder.loadingView()
                } else if viewModel.error != nil {
                    WidgetContentBuilder.errorView(t("widgets__blocks__error"))
                } else if let data = viewModel.blockData {
                    VStack(spacing: 0) {
                        // Display block data rows based on options
                        ForEach(options.displayRows(for: data), id: \.key) { item in
                            HStack(spacing: 0) {
                                HStack {
                                    BodySSBText(item.label, textColor: .textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                HStack {
                                    BodyMSBText(item.value)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .frame(minHeight: 28)
                        }

                        if options.showSource {
                            WidgetContentBuilder.sourceRow(source: "mempool.space")
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.startUpdates()
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
