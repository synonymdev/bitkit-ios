import Foundation

enum WeatherDisplayMetric: String, Codable, CaseIterable {
    case fiatFee
    case satsFee
    case nextBlockFee
}

struct WeatherWidgetOptions: Codable, Equatable {
    var selectedMetric: WeatherDisplayMetric = .fiatFee

    init(selectedMetric: WeatherDisplayMetric = .fiatFee) {
        self.selectedMetric = selectedMetric
    }

    private enum CodingKeys: String, CodingKey {
        case selectedMetric
        // Legacy v60 keys — still read on decode so users upgrading from the four-toggle layout
        // keep their prior choice (and backup export sees the right metric, since it decodes
        // through this type before converting to the cross-platform format).
        case showMedian
        case showNextBlockFee
    }

    /// Custom decoder so users upgrading from the v60 four-toggle blob aren't silently reset to
    /// `.fiatFee`. Mapping rules, in priority order:
    ///   1. New `selectedMetric` key wins when present.
    ///   2. `showMedian` (legacy "Current Fee" toggle) → `.fiatFee`.
    ///   3. `showNextBlockFee` alone → `.nextBlockFee`.
    ///   4. Neither present / both `false` → default `.fiatFee`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let metric = try container.decodeIfPresent(WeatherDisplayMetric.self, forKey: .selectedMetric) {
            selectedMetric = metric
            return
        }

        let showMedian = try container.decodeIfPresent(Bool.self, forKey: .showMedian) ?? false
        let showNextBlockFee = try container.decodeIfPresent(Bool.self, forKey: .showNextBlockFee) ?? false

        if showMedian {
            selectedMetric = .fiatFee
        } else if showNextBlockFee {
            selectedMetric = .nextBlockFee
        } else {
            selectedMetric = .fiatFee
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedMetric, forKey: .selectedMetric)
    }
}
