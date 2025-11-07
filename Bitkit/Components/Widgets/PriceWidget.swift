import Charts
import SwiftUI

/// Options for configuring the PriceWidget
struct PriceWidgetOptions: Codable, Equatable {
    var selectedPairs: [String] = ["BTC/USD"]
    var selectedPeriod: GraphPeriod = .oneDay
    var showSource: Bool = false
}

/// A widget that displays cryptocurrency price information with chart
struct PriceWidget: View {
    /// Configuration options for the widget
    var options: PriceWidgetOptions = .init()

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// Price view model singleton
    @StateObject private var viewModel = PriceViewModel.shared

    /// Initialize the widget
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
            VStack(spacing: 0) {
                if viewModel.isLoading && filteredPriceData.isEmpty {
                    WidgetContentBuilder.loadingView()
                } else if viewModel.error != nil {
                    WidgetContentBuilder.errorView(t("widgets__price__error"))
                } else {
                    ForEach(filteredPriceData, id: \.name) { priceData in
                        PriceRow(data: priceData)
                            .accessibilityIdentifier("PriceWidgetRow-\(priceData.name)")
                    }
                }

                if let firstPair = filteredPriceData.first {
                    PriceChart(
                        values: firstPair.pastValues,
                        isPositive: firstPair.change.isPositive,
                        period: options.selectedPeriod.rawValue
                    )
                    .frame(height: 96)
                    .padding(.top, 8)
                }

                if options.showSource {
                    WidgetContentBuilder.sourceRow(source: "Bitfinex.com")
                        .accessibilityIdentifier("PriceWidgetSource")
                }
            }
        }
        .onAppear {
            fetchPriceData()
        }
        .onChange(of: options.selectedPairs) { _ in
            fetchPriceData()
        }
        .onChange(of: options.selectedPeriod) { _ in
            fetchPriceData()
        }
    }

    private var filteredPriceData: [PriceData] {
        let currentPeriodData = viewModel.getCurrentData(for: options.selectedPeriod)
        let dataByPair = Dictionary(uniqueKeysWithValues: currentPeriodData.map { ($0.name, $0) })
        return options.selectedPairs.compactMap { pair in
            dataByPair[pair]
        }
    }

    /// Fetch price data from view model
    private func fetchPriceData() {
        viewModel.fetchPriceData(pairs: options.selectedPairs, period: options.selectedPeriod)
    }
}

// MARK: - Price Row Component

struct PriceRow: View {
    let data: PriceData

    var body: some View {
        HStack {
            BodySSBText(data.name, textColor: .textSecondary)

            Spacer()

            BodySSBText(data.change.formatted, textColor: data.change.isPositive ? .greenAccent : .redAccent)
                .padding(.trailing, 8)
            BodySSBText(data.price, textColor: .textPrimary)
        }
        .frame(minHeight: 28)
    }
}

// MARK: - Price Chart Component

struct PriceChart: View {
    let values: [Double]
    let isPositive: Bool
    let period: String

    // Chart styling constants
    private let lineWidth: CGFloat = 1.3
    private let chartPadding: CGFloat = 4
    private let cornerRadius: CGFloat = 8
    private let gradientOpacityTop: CGFloat = 0.64
    private let gradientOpacityBottom: CGFloat = 0.08

    private var normalizedValues: [Double] {
        guard values.count > 1 else { return values }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = maxValue - minValue

        guard range > 0 else { return values.map { _ in 0.5 } }

        // Map to 0.15...0.85 range for more generous margins
        // This prevents chart content from reaching the very edges where clipping occurs
        return values.map { value in
            let normalized = (value - minValue) / range
            return 0.15 + (normalized * 0.7) // Maps 0-1 to 0.15-0.85
        }
    }

    private var chartColors: (gradient: [Color], line: Color) {
        if isPositive {
            return (
                gradient: [.greenAccent.opacity(gradientOpacityTop), .greenAccent.opacity(gradientOpacityBottom)],
                line: .greenAccent
            )
        } else {
            return (
                gradient: [.redAccent.opacity(gradientOpacityTop), .redAccent.opacity(gradientOpacityBottom)],
                line: .redAccent
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Chart {
                ForEach(Array(normalizedValues.enumerated()), id: \.offset) { index, value in
                    // Area fill with gradient
                    AreaMark(
                        x: .value("Index", index),
                        y: .value("Price", value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: chartColors.gradient,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    // Line on top
                    LineMark(
                        x: .value("Index", index),
                        y: .value("Price", value)
                    )
                    .foregroundStyle(chartColors.line)
                    .lineStyle(StrokeStyle(lineWidth: lineWidth))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Y scale domain provides buffer zone beyond data range (0.15...0.85)
            // This ensures chart elements (lines, curves) don't get clipped at edges
            .chartYScale(domain: 0.1 ... 0.9) // Domain slightly larger than data range for extra buffer
            // Apply rounded corners only to bottom - chart content extends to edges for visible clipping
            // The internal margins above prevent any actual data from being cut off
            .clipShape(
                .rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: 0
                )
            )

            // Period label
            CaptionBText(period, textColor: isPositive ? .green50 : .red50)
                .padding(7)
        }
    }
}

#Preview {
    PriceWidget()
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
