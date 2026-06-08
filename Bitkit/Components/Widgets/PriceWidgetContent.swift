import Charts
import SwiftUI
import WidgetKit

// Shared Bitcoin Price widget content, reused by the in-app feed, the carousel preview, and the
// home-screen WidgetKit extension. Colors adapt to `widgetRenderingMode` via ``WidgetPalette``.
//
// Card chrome (padding/background/corner) is supplied by the caller, not here.

// MARK: - Wide layout (in-app + 343-wide carousel page + .systemMedium OS widget)

struct PriceWidgetWideContent: View {
    let data: PriceData
    let period: GraphPeriod

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 16) {
                    CaptionMText("\(data.name)  \(period.rawValue)", textColor: palette.secondary)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TitleText(
                        data.change.formatted,
                        textColor: palette.data(data.change.isPositive ? .greenAccent : .redAccent)
                    )
                    .lineLimit(1)
                    .widgetAccentable()
                    .accessibilityIdentifier("price_card_pair_change_\(data.name)")
                }
                .accessibilityIdentifier("PriceWidgetRow-\(data.name)")

                Text(data.price)
                    .font(Fonts.bold(size: 34))
                    .foregroundColor(palette.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetAccentable()
                    .accessibilityIdentifier("price_card_pair_price_\(data.name)")
            }

            PriceChart(values: data.pastValues, isPositive: data.change.isPositive, renderingMode: renderingMode)
                .frame(height: 48)
                .widgetAccentable()
                .accessibilityIdentifier("price_card_chart")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compact layout (small carousel preview + .systemSmall OS widget)

struct PriceWidgetCompactContent: View {
    let data: PriceData
    let period: GraphPeriod

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    CaptionMText(data.name, textColor: palette.secondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                    CaptionMText(period.rawValue, textColor: palette.secondary)
                        .textCase(.uppercase)
                }
                .accessibilityIdentifier("PriceWidgetRow-\(data.name)")

                Text(data.price)
                    .font(Fonts.bold(size: 22))
                    .foregroundColor(palette.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()
                    .accessibilityIdentifier("price_card_small_pair_price_\(data.name)")

                BodySSBText(
                    data.change.formatted,
                    textColor: palette.data(data.change.isPositive ? .greenAccent : .redAccent)
                )
                .lineLimit(1)
                .widgetAccentable()
                .accessibilityIdentifier("price_card_small_pair_change_\(data.name)")
            }

            Spacer(minLength: 8)

            PriceChart(values: data.pastValues, isPositive: data.change.isPositive, renderingMode: renderingMode)
                .frame(height: 64)
                .widgetAccentable()
                .accessibilityIdentifier("price_card_small_chart")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Chart

struct PriceChart: View {
    let values: [Double]
    let isPositive: Bool
    /// Defaults to `.fullColor` so non-widget callers render the colored line.
    var renderingMode: WidgetRenderingMode = .fullColor

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
        guard renderingMode == .fullColor else { return .primary }
        return isPositive ? .greenAccent : .redAccent
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
