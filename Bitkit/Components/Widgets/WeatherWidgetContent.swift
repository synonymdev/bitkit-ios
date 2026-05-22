import SwiftUI
import WidgetKit

// MARK: - Display metric helpers

extension WeatherDisplayMetric {
    var labelKey: String {
        switch self {
        case .fiatFee, .satsFee:
            return "widgets__weather__current_fee"
        case .nextBlockFee:
            return "widgets__weather__next_block"
        }
    }

    func value(from data: CachedWeather) -> String {
        switch self {
        case .fiatFee:
            return data.currentFeeFiat
        case .satsFee:
            return "₿ \(data.currentFeeSats)"
        case .nextBlockFee:
            return "\(data.nextBlockFee) ₿/VBYTE"
        }
    }

    var fallbackPreviewValue: String {
        switch self {
        case .fiatFee: return "$ 0.52"
        case .satsFee: return "₿ 520"
        case .nextBlockFee: return "6 ₿/VBYTE"
        }
    }
}

// MARK: - Shared metric block

struct WeatherFeeMetric: View {
    let label: String
    let value: String
    var valueColor: Color = .greenAccent
    var valueSize: CGFloat = 30
    /// Use a smaller label (`FootnoteText`) so the caption doesn't dominate the value
    /// in the space-constrained compact widget.
    var compactLabel: Bool = false

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        VStack(alignment: .leading, spacing: 4) {
            labelView(palette: palette)
            Text(value)
                .font(Fonts.bold(size: valueSize))
                .foregroundColor(palette.data(valueColor))
                .kerning(-1)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private func labelView(palette: WidgetPalette) -> some View {
        if compactLabel {
            FootnoteText(label, textColor: palette.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            CaptionMText(label, textColor: palette.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
        }
    }
}

struct WeatherWidgetWideContent: View {
    let data: CachedWeather
    let metric: WeatherDisplayMetric
    let conditionTitle: String
    let conditionDescription: String
    let metricLabel: String

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SubtitleText(conditionTitle, textColor: palette.title)
                    BodySText(conditionDescription, textColor: palette.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WeatherFeeMetric(
                    label: metricLabel,
                    value: metric.value(from: data),
                    valueColor: data.condition.valueColor
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(data.condition.icon)
                .font(.system(size: 82))
                .frame(width: 82, height: 82)
                .widgetAccentable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WeatherWidgetCompactContent: View {
    let data: CachedWeather
    let metric: WeatherDisplayMetric
    let conditionTitle: String
    let metricLabel: String

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                Text(data.condition.icon)
                    .font(.system(size: 58))
                    .minimumScaleFactor(0.85)
                    .widgetAccentable()
                SubtitleText(conditionTitle, textColor: palette.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            WeatherFeeMetric(
                label: metricLabel,
                value: metric.value(from: data),
                valueColor: data.condition.valueColor,
                valueSize: 28,
                compactLabel: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
