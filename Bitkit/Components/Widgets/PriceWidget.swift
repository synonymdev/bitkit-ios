import Charts
import SwiftUI

/// Displays Bitcoin price for the user's selected trading pair and timeframe (Figma v61).
struct PriceWidget: View {
    var options: PriceWidgetOptions = .init()
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = PriceViewModel.shared

    init(
        options: PriceWidgetOptions = PriceWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .price,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            content
        }
        .onAppear { fetchPriceData() }
        .onChange(of: options.selectedPairs) { fetchPriceData() }
        .onChange(of: options.selectedPeriod) { fetchPriceData() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && primaryPrice == nil {
            WidgetContentBuilder.loadingView()
        } else if viewModel.error != nil {
            WidgetContentBuilder.errorView(t("widgets__price__error"))
        } else if let primary = primaryPrice {
            PriceWidgetWideContent(data: primary, period: options.selectedPeriod)
        }
    }

    /// Single pair (v61). Falls back to first available data if the selection isn't loaded yet.
    private var primaryPrice: PriceData? {
        let currentPeriodData = viewModel.getCurrentData(for: options.selectedPeriod)
        if let preferred = options.selectedPairs.first,
           let match = currentPeriodData.first(where: { $0.name == preferred })
        {
            return match
        }
        return currentPeriodData.first
    }

    private func fetchPriceData() {
        viewModel.fetchPriceData(pairs: options.selectedPairs, period: options.selectedPeriod)
    }
}

// MARK: - Wide layout (in-app + carousel page)

struct PriceWidgetWideContent: View {
    let data: PriceData
    let period: GraphPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 16) {
                    CaptionMText("\(data.name)  \(period.rawValue)", textColor: .textSecondary)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TitleText(
                        data.change.formatted,
                        textColor: data.change.isPositive ? .greenAccent : .redAccent
                    )
                    .lineLimit(1)
                }

                Text(data.price)
                    .font(Fonts.bold(size: 34))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PriceChart(values: data.pastValues, isPositive: data.change.isPositive)
                .frame(height: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compact layout (small carousel preview only)

struct PriceWidgetCompactContent: View {
    let data: PriceData
    let period: GraphPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    CaptionMText(data.name, textColor: .textSecondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                    CaptionMText(period.rawValue, textColor: .textSecondary)
                        .textCase(.uppercase)
                }

                Text(data.price)
                    .font(Fonts.bold(size: 22))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                BodySSBText(
                    data.change.formatted,
                    textColor: data.change.isPositive ? .greenAccent : .redAccent
                )
                .lineLimit(1)
            }

            PriceChart(values: data.pastValues, isPositive: data.change.isPositive)
                .frame(height: 64)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}

// MARK: - Chart (line-only per Figma v61)

struct PriceChart: View {
    let values: [Double]
    let isPositive: Bool

    private let lineWidth: CGFloat = 1.3

    private var normalizedValues: [Double] {
        guard values.count > 1 else { return values }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = maxValue - minValue

        guard range > 0 else { return values.map { _ in 0.5 } }

        return values.map { value in
            let normalized = (value - minValue) / range
            return 0.15 + (normalized * 0.7)
        }
    }

    private var lineColor: Color {
        isPositive ? .greenAccent : .redAccent
    }

    var body: some View {
        Chart {
            ForEach(Array(normalizedValues.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Index", index),
                    y: .value("Price", value)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: lineWidth))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0.1 ... 0.9)
    }
}

#Preview {
    PriceWidget()
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
