import SwiftUI

// MARK: - Display metric helpers

extension WeatherDisplayMetric {
    /// Localization key for the uppercase caption shown above the metric value.
    var labelKey: String {
        switch self {
        case .fiatFee, .satsFee:
            return "widgets__weather__current_fee"
        case .nextBlockFee:
            return "widgets__weather__next_block"
        }
    }

    /// Hard-coded English label used inside the WidgetKit extension where the `t()` helper
    /// is not available. Values are uppercased at render via `.textCase(.uppercase)`.
    var englishLabel: String {
        switch self {
        case .fiatFee, .satsFee:
            return "Current fee"
        case .nextBlockFee:
            return "Next block inclusion"
        }
    }

    /// Render value text from a cached weather snapshot.
    func value(from data: CachedWeather) -> String {
        switch self {
        case .fiatFee:
            return data.currentFeeFiat
        case .satsFee:
            return "₿ \(data.currentFeeSats)"
        case .nextBlockFee:
            return "\(data.nextBlockFee) ₿/vbyte"
        }
    }

    /// Stable preview value used in the edit screen when no real data is available.
    var fallbackPreviewValue: String {
        switch self {
        case .fiatFee: return "$ 0.52"
        case .satsFee: return "₿ 520"
        case .nextBlockFee: return "6 ₿/vbyte"
        }
    }
}

// MARK: - Shared metric block (caption + big green value)

struct WeatherFeeMetric: View {
    let label: String
    let value: String
    var valueColor: Color = .greenAccent
    var valueSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Fonts.medium(size: 13))
                .foregroundColor(.white.opacity(0.64))
                .kerning(1)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(Fonts.bold(size: valueSize))
                .foregroundColor(valueColor)
                .kerning(-1)
                .lineLimit(1)
        }
    }
}

// MARK: - Wide content (in-app + .systemMedium OS widget + wide carousel page)

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
                    Text(conditionTitle)
                        .font(Fonts.bold(size: 17))
                        .foregroundColor(.white)
                    Text(conditionDescription)
                        .font(Fonts.regular(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                }

                WeatherFeeMetric(label: metricLabel, value: metric.value(from: data))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(data.condition.icon)
                .font(.system(size: 82))
                .frame(width: 82, height: 82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compact content (.systemSmall OS widget + small carousel page)

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
                Text(conditionTitle)
                    .font(Fonts.bold(size: 17))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Spacer()

            WeatherFeeMetric(
                label: metricLabel,
                value: metric.value(from: data),
                valueSize: 22
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
