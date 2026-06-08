import SwiftUI

/// Displays Bitcoin price for the user's selected trading pair and timeframe.
struct PriceWidget: View {
    var options: PriceWidgetOptions = .init()
    var size: WidgetSize = .wide
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = PriceViewModel.shared

    init(
        options: PriceWidgetOptions = PriceWidgetOptions(),
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
            type: .price,
            size: size,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            content
        }
        .task(id: options) { fetchPriceData() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && primaryPrice == nil {
            WidgetContentBuilder.loadingView()
        } else if viewModel.error != nil {
            WidgetContentBuilder.errorView(t("widgets__price__error"))
        } else if let primary = primaryPrice {
            if size == .small {
                PriceWidgetCompactContent(data: primary, period: options.selectedPeriod)
            } else {
                PriceWidgetWideContent(data: primary, period: options.selectedPeriod)
            }
        }
    }

    /// Single pair. Falls back to first available data if the selection isn't loaded yet.
    private var primaryPrice: PriceData? {
        let currentPeriodData = viewModel.getCurrentData(for: options.selectedPeriod)
        if let match = currentPeriodData.first(where: { $0.name == options.selectedPair }) {
            return match
        }
        return currentPeriodData.first
    }

    private func fetchPriceData() {
        viewModel.fetchPriceData(pairs: [options.selectedPair], period: options.selectedPeriod)
    }
}

#Preview {
    PriceWidget()
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
