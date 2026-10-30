import SwiftUI

/// MoneyText - Single text display component for monetary values
enum MoneySize {
    case display
    case title
    case subtitle
    case bodyMSB
    case bodySSB
    case caption
    case captionB
}

enum MoneyUnitType {
    case primary
    case secondary
}

struct MoneyText: View {
    let sats: Int
    var isUnavailable = false
    var unitType: MoneyUnitType = .primary
    /// When set, overrides user preference so the value is always shown in this unit.
    var forceUnit: PrimaryDisplay?
    /// When set, overrides user preference so the value is always shown in this denomination.
    var forceDisplayUnit: BitcoinDisplayUnit?
    var size: MoneySize = .display
    var symbol: Bool?
    var enableHide: Bool = false
    var prefix: String?
    var color: Color = .textPrimary
    var symbolColor: Color?
    var testIdentifier: String?
    var fillsWidth: Bool = true
    var kerning: CGFloat?
    var lineHeight: CGFloat?
    /// When set, the amount's digits (or hidden dots) shimmer while it is true; the symbol is left as is.
    var shimmer: Bool?

    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var leadingWidth: CGFloat = 0
    @State private var amountWidth: CGFloat = 0
    @State private var amountHeight: CGFloat = 0
    @State private var amountTop: CGFloat = 0

    // MARK: - Computed Properties

    private var unit: PrimaryDisplay {
        if let forceUnit {
            return forceUnit
        }
        return unitType == .secondary ? (currency.primaryDisplay == .bitcoin ? .fiat : .bitcoin) : currency.primaryDisplay
    }

    private var showSymbol: Bool {
        symbol ?? (unit == .fiat)
    }

    private var hideBalance: Bool {
        enableHide && settings.hideBalance
    }

    private var displayDots: String {
        size == .display ? " • • • • • • • • •" : " • • • • •"
    }

    private var displayText: String {
        leadingText + formattedValue + trailingText
    }

    /// Markup before the amount: the prefix and a leading symbol.
    private var leadingText: String {
        if showSymbol {
            let baseSymbol = unit == .bitcoin ? "₿" : fiatSymbol
            if unit == .fiat && isFiatSymbolSuffix {
                return prefix != nil ? "<accent>\(prefix!)</accent> " : ""
            }
            return prefix != nil ? "<accent>\(prefix!) \(baseSymbol)</accent> " : "<accent>\(baseSymbol)</accent> "
        }
        return prefix != nil ? "<accent>\(prefix!)</accent> " : ""
    }

    /// Markup after the amount: a trailing symbol.
    private var trailingText: String {
        guard showSymbol, unit == .fiat, isFiatSymbolSuffix else { return "" }
        return " <accent>\(fiatSymbol)</accent>"
    }

    var body: some View {
        labeledText
            // Outside the identifier above, so this element keeps its own identifier.
            .overlay {
                if shimmer == true {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(t("wallet__balance_updating"))
                        .accessibilityIdentifier("TotalBalanceUpdating")
                }
            }
    }

    @ViewBuilder
    private var labeledText: some View {
        let base = shimmering(textComponent(displayText).foregroundColor(color))

        if let testIdentifier {
            base
                .accessibilityIdentifier(testIdentifier)
                .accessibilityLabel(accessibilityValue)
                // Expose the symbol as a separate accessibility node so our E2E tests
                // can target it independently (mirrors the Android accessibility tree).
                .overlay(alignment: .leading) {
                    if let symbolText {
                        Text(symbolText)
                            .foregroundColor(.clear)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("MoneyFiatSymbol")
                            .accessibilityLabel(symbolText)
                    }
                }
        } else {
            base
        }
    }
}

// MARK: - Helper Views

extension MoneyText {
    @ViewBuilder
    private func shimmering(_ content: some View) -> some View {
        if let shimmer {
            content
                .modifier(AmountShimmer(
                    isActive: shimmer,
                    leadingWidth: leadingWidth,
                    amountWidth: amountWidth,
                    amountHeight: amountHeight,
                    amountTop: amountTop
                ))
                .background(amountMeasurer)
                .onPreferenceChange(AmountMetricsKey.self) { metrics in
                    let total = metrics[.totalWidth] ?? 0
                    let amount = metrics[.amountWidth] ?? 0
                    let height = metrics[.amountHeight] ?? 0
                    let totalHeight = metrics[.totalHeight] ?? 0
                    // A leading symbol that wraps puts the amount on its own line below it.
                    let symbolWraps = height > 0 && totalHeight > height * 1.5
                    leadingWidth = symbolWraps ? 0 : max(0, total - amount)
                    amountWidth = amount
                    amountHeight = height
                    amountTop = symbolWraps ? totalHeight - height : 0
                }
        } else {
            content
        }
    }

    /// Hidden copies that measure where the amount sits inside the full text.
    private var amountMeasurer: some View {
        ZStack(alignment: .leading) {
            textComponent(leadingText + formattedValue, fillsWidth: false)
                .background(GeometryReader { Color.clear.preference(
                    key: AmountMetricsKey.self,
                    value: [.totalWidth: $0.size.width, .totalHeight: $0.size.height]
                ) })
            textComponent(formattedValue, fillsWidth: false)
                .background(GeometryReader {
                    Color.clear.preference(key: AmountMetricsKey.self, value: [.amountWidth: $0.size.width, .amountHeight: $0.size.height])
                })
        }
        .hidden()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func textComponent(_ text: String, fillsWidth: Bool? = nil) -> some View {
        switch size {
        case .display:
            DisplayText(
                // Cap symbol font weight to ExtraBold
                text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                accentFont: Fonts.extraBold, fillsWidth: fillsWidth ?? self.fillsWidth, kerning: kerning ?? -1, lineHeight: lineHeight
            )
        case .title:
            TitleText(text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                      kerning: kerning ?? 0.4, lineHeight: lineHeight)
        case .subtitle:
            SubtitleText(text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                         kerning: kerning ?? 0.4, lineHeight: lineHeight)
        case .bodyMSB:
            BodyMSBText(text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                        kerning: kerning ?? 0.4, lineHeight: lineHeight)
        case .bodySSB:
            BodySSBText(text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                        kerning: kerning ?? 0.4, lineHeight: lineHeight)
        case .caption:
            CaptionMText(text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                         kerning: kerning ?? 0.8, lineHeight: lineHeight)
        case .captionB:
            CaptionBText(text, textColor: color, accentColor: symbolColor ?? .textSecondary,
                         kerning: kerning ?? 0.4, lineHeight: lineHeight)
        }
    }
}

// MARK: - Helper Methods

extension MoneyText {
    private var fiatSymbol: String {
        guard let converted = currency.convert(sats: UInt64(abs(sats))) else { return "$" }
        return converted.symbol
    }

    private var isFiatSymbolSuffix: Bool {
        isSuffixSymbolCurrency(currency.selectedCurrency)
    }

    private var formattedValue: String {
        if hideBalance {
            return displayDots
        }
        if isUnavailable {
            return "—"
        }

        if let converted = currency.convert(sats: UInt64(abs(sats))) {
            switch unit {
            case .fiat:
                return converted.formatted
            case .bitcoin:
                let displayUnit = forceDisplayUnit ?? currency.displayUnit
                return converted.bitcoinDisplay(unit: displayUnit).value
            }
        }

        // Rates unavailable: show sats for bitcoin, "0" for fiat
        if unit == .bitcoin {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = " "
            return formatter.string(from: NSNumber(value: abs(sats))) ?? String(abs(sats))
        }
        return "0"
    }

    private var symbolText: String? {
        guard showSymbol else { return nil }
        return unit == .bitcoin ? "₿" : fiatSymbol
    }

    private var accessibilityValue: String {
        if !hideBalance, isUnavailable {
            return "—"
        }
        guard !hideBalance, let converted = currency.convert(sats: UInt64(abs(sats))) else {
            return prefixed(displayDots)
        }

        let numeric: String = {
            switch unit {
            case .fiat:
                return stripSymbol(converted.formatted, symbol: converted.symbol)
            case .bitcoin:
                return converted.bitcoinDisplay(unit: currency.displayUnit).value
            }
        }()

        return prefixed(numeric)
    }

    private func prefixed(_ value: String) -> String {
        guard let prefix, !prefix.isEmpty else { return value }
        return "\(prefix) \(value)"
    }

    private func stripSymbol(_ string: String, symbol: String) -> String {
        guard let range = string.range(of: symbol) else {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var copy = string
        copy.removeSubrange(range)
        return copy.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Preview Helpers

private extension MoneyText {
    static func previewCurrencyVM(
        primaryDisplay: PrimaryDisplay,
        currency: String,
        displayUnit: BitcoinDisplayUnit = .modern
    ) -> CurrencyViewModel {
        let vm = CurrencyViewModel()
        vm.primaryDisplay = primaryDisplay
        vm.selectedCurrency = currency
        vm.displayUnit = displayUnit
        return vm
    }

    static func previewSettingsVM(hideBalance: Bool = false) -> SettingsViewModel {
        let vm = SettingsViewModel.shared
        vm.hideBalance = hideBalance
        return vm
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            // Primary display (Bitcoin)
            MoneyText(sats: 123_456, unitType: .primary, size: .display)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM())

            // Secondary display (Fiat)
            MoneyText(sats: 123_456, unitType: .secondary, size: .caption)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM())

            // With prefix
            MoneyText(sats: 123_456, prefix: "+", color: .green)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .fiat, currency: "EUR"))
                .environmentObject(MoneyText.previewSettingsVM())

            // Hidden balance
            MoneyText(sats: 123_456, enableHide: true)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM(hideBalance: true))

            // No symbol
            MoneyText(sats: 123_456, symbol: false)
                .environmentObject(MoneyText.previewCurrencyVM(primaryDisplay: .fiat, currency: "USD"))
                .environmentObject(MoneyText.previewSettingsVM())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}

private enum AmountMetric: Hashable {
    case totalWidth
    case totalHeight
    case amountWidth
    case amountHeight
}

private struct AmountMetricsKey: PreferenceKey {
    static let defaultValue: [AmountMetric: CGFloat] = [:]

    static func reduce(value: inout [AmountMetric: CGFloat], nextValue: () -> [AmountMetric: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A soft diagonal sweep over the amount while its balance refreshes. The digits dim to 75% and the band brings them
/// back to full, so the cached amount stays readable; the symbol is not touched. With Reduce Motion on, the digits only dim.
private struct AmountShimmer: ViewModifier {
    let isActive: Bool
    let leadingWidth: CGFloat
    let amountWidth: CGFloat
    /// One line of the amount: when the text wraps, only that line shimmers, so a symbol on another line stays steady.
    let amountHeight: CGFloat
    /// Where the amount's line starts when a leading symbol wraps above it; 0 when the amount starts the text.
    let amountTop: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var intensity: Double = 0
    @State private var isSweeping = false
    /// Bumped on every change, so a fade-out that finishes after a newer change leaves the sweep running.
    @State private var changeCount = 0

    private let sweepDuration: TimeInterval = 2
    private let minOpacity = 0.75
    private let bandWidth: CGFloat = 56
    /// `DisplayText` draws glyph tops and descenders outside its frame; the mask reaches past it so they stay visible.
    private let maskOutset: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    let height = proxy.size.height
                    let wraps = amountHeight > 0 && height - 2 * maskOutset > amountHeight * 1.5
                    let top = wraps && amountTop > 0 ? maskOutset + amountTop : 0
                    VStack(spacing: 0) {
                        Color.white.frame(height: top)
                        shimmerRow
                            .frame(height: !wraps ? height : amountTop > 0 ? height - top : maskOutset + amountHeight)
                        Color.white
                    }
                }
                .padding(-maskOutset)
            }
            .onAppear {
                intensity = isActive ? 1 : 0
                isSweeping = isActive
            }
            .onChange(of: isActive) { _, active in
                changeCount += 1
                let change = changeCount
                if active {
                    isSweeping = true
                }
                withAnimation(.easeInOut(duration: 0.3)) {
                    intensity = active ? 1 : 0
                } completion: {
                    if !active, change == changeCount {
                        isSweeping = false
                    }
                }
            }
    }

    private var shimmerRow: some View {
        HStack(spacing: 0) {
            Color.white.frame(width: maskOutset + leadingWidth)
            ZStack {
                Color.white.opacity(minOpacity)
                if !reduceMotion {
                    TimelineView(.animation(paused: !isSweeping)) { context in
                        GeometryReader { proxy in
                            band(at: context.date, in: proxy.size)
                        }
                    }
                }
                Color.white.opacity(1 - intensity)
            }
            .frame(width: amountWidth)
            .clipped()
            Color.white
        }
    }

    /// A diagonal band, as on Android: its edges slope by one line of the amount over the band's width, and it travels
    /// from fully before the amount to fully past it, so each pass starts and ends off the digits.
    private func band(at date: Date, in size: CGSize) -> some View {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepDuration) / sweepDuration
        let half = bandWidth / 2
        let rise = amountHeight > 0 ? amountHeight : size.height
        let overshoot = half + size.height * rise / (2 * half)
        let center = -overshoot + phase * (size.width + 2 * overshoot)
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        return LinearGradient(
            colors: [.clear, .white, .clear],
            startPoint: UnitPoint(x: (center - half) / width, y: 0),
            endPoint: UnitPoint(x: (center + half) / width, y: rise / height)
        )
    }
}
