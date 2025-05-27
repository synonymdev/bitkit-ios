import SwiftUI

/// Options for configuring the FactsWidget
struct FactsWidgetOptions {
    var showSource: Bool = true
}

struct FactsWidget: View {
    /// Configuration options for the widget
    var options: FactsWidgetOptions = FactsWidgetOptions()

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
        self._viewModel = StateObject(wrappedValue: viewModel)
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
                    HStack(spacing: 0) {
                        HStack {
                            CaptionBText(localizedString("widgets__widget__source"))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            CaptionBText("synonym.to")
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.top, 16)
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
