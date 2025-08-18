import SwiftUI

/// Options for configuring the BlocksWidget
struct BlocksWidgetOptions: Codable, Equatable {
    var height: Bool = true
    var time: Bool = true
    var date: Bool = true
    var transactionCount: Bool = false
    var size: Bool = false
    var weight: Bool = false
    var difficulty: Bool = false
    var hash: Bool = false
    var merkleRoot: Bool = false
    var showSource: Bool = false
}

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

    /// Mapping of block data keys to display labels
    private let blocksMapping: [String: String] = [
        "height": "Block",
        "time": "Time",
        "date": "Date",
        "transactionCount": "Transactions",
        "size": "Size",
        "weight": "Weight",
        "difficulty": "Difficulty",
        "hash": "Hash",
        "merkleRoot": "Merkle Root",
    ]

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
                        ForEach(getDisplayableData(data), id: \.key) { item in
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

    /// Get displayable data based on current options
    private func getDisplayableData(_ data: BlockData) -> [(key: String, label: String, value: String)] {
        var items: [(key: String, label: String, value: String)] = []

        if options.height {
            items.append((key: "height", label: blocksMapping["height"]!, value: data.height))
        }
        if options.time {
            items.append((key: "time", label: blocksMapping["time"]!, value: data.time))
        }
        if options.date {
            items.append((key: "date", label: blocksMapping["date"]!, value: data.date))
        }
        if options.transactionCount {
            items.append((key: "transactionCount", label: blocksMapping["transactionCount"]!, value: data.transactionCount))
        }
        if options.size {
            items.append((key: "size", label: blocksMapping["size"]!, value: data.size))
        }
        if options.weight {
            items.append((key: "weight", label: blocksMapping["weight"]!, value: data.weight))
        }
        if options.difficulty {
            items.append((key: "difficulty", label: blocksMapping["difficulty"]!, value: data.difficulty))
        }
        if options.hash {
            items.append((key: "hash", label: blocksMapping["hash"]!, value: data.hash))
        }
        if options.merkleRoot {
            items.append((key: "merkleRoot", label: blocksMapping["merkleRoot"]!, value: data.merkleRoot))
        }

        return items
    }
}

#Preview {
    BlocksWidget()
        .padding()
        .background(.black)
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
