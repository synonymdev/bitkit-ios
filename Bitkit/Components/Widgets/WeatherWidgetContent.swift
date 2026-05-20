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
        case .nextBlockFee: return "6 ₿/vbyte"
        }
    }
}

// MARK: - Shared metric block

struct WeatherFeeMetric: View {
    let label: String
    let value: String
    var valueColor: Color = .greenAccent
    var valueSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptionMText(label, textColor: .white64)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(Fonts.bold(size: valueSize))
                .foregroundColor(valueColor)
                .kerning(-1)
                .lineLimit(1)
                .widgetAccentable()
        }
    }
}

struct WeatherWidgetWideContent: View {
    let data: CachedWeather
    let metric: WeatherDisplayMetric
    let conditionTitle: String
    let conditionDescription: String
    let metricLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SubtitleText(conditionTitle, textColor: .white)
                    BodySText(conditionDescription, textColor: .white80)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WeatherFeeMetric(label: metricLabel, value: metric.value(from: data))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.condition.icon)
                    .font(.system(size: 52))
                    .widgetAccentable()
                SubtitleText(conditionTitle, textColor: .white)
                    .lineLimit(1)
            }
            .padding(.top, 16)

            WeatherFeeMetric(
                label: metricLabel,
                value: metric.value(from: data),
                valueSize: 22
            )
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
