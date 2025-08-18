import SwiftUI

/// Options for configuring the FactsWidget
struct FactsWidgetOptions: Codable, Equatable {
    var showSource: Bool = true
}

struct FactsWidget: View {
    /// Configuration options for the widget
    var options: FactsWidgetOptions = .init()

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// View model for handling facts data
    @StateObject private var viewModel = FactsViewModel.shared

    /// Initialize the widget
    init(
        options: FactsWidgetOptions = FactsWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    /// Initialize with a custom view model (for previews)
    init(
        viewModel: FactsViewModel,
        options: FactsWidgetOptions = FactsWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        BaseWidget(
            type: .facts,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            VStack(spacing: 0) {
                TitleText(viewModel.fact)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if options.showSource {
                    WidgetContentBuilder.sourceRow(source: "synonym.to")
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        FactsWidget()

        FactsWidget(
            options: FactsWidgetOptions(showSource: false)
        )

        FactsWidget(
            isEditing: true
        )
    }
    .padding()
    .background(Color.black)
    .environmentObject(WalletViewModel())
    .preferredColorScheme(.dark)
}
