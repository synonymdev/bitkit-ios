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
                .modifier(AmountShimmer(isActive: shimmer, leadingWidth: leadingWidth, amountWidth: amountWidth))
                .background(amountMeasurer)
                .onPreferenceChange(AmountWidthsKey.self) { widths in
                    let total = widths[.total] ?? 0
                    let amount = widths[.amount] ?? 0
                    leadingWidth = max(0, total - amount)
                    amountWidth = amount
                }
        } else {
            content
        }
    }

    /// Hidden copies that measure where the amount sits inside the full text.
    private var amountMeasurer: some View {
        ZStack(alignment: .leading) {
            textComponent(leadingText + formattedValue, fillsWidth: false)
                .background(GeometryReader { Color.clear.preference(key: AmountWidthsKey.self, value: [.total: $0.size.width]) })
            textComponent(formattedValue, fillsWidth: false)
                .background(GeometryReader { Color.clear.preference(key: AmountWidthsKey.self, value: [.amount: $0.size.width]) })
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

private enum AmountWidth: Hashable {
    case total
    case amount
}

private struct AmountWidthsKey: PreferenceKey {
    static let defaultValue: [AmountWidth: CGFloat] = [:]

    static func reduce(value: inout [AmountWidth: CGFloat], nextValue: () -> [AmountWidth: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A soft diagonal sweep over the amount while its balance refreshes. The digits dim to 75% and the band brings them
/// back to full, so the cached amount stays readable; the symbol is not touched. With Reduce Motion on, the digits only dim.
private struct AmountShimmer: ViewModifier {
    let isActive: Bool
    let leadingWidth: CGFloat
    let amountWidth: CGFloat

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
                HStack(spacing: 0) {
                    Color.white.frame(width: maskOutset + leadingWidth)
                    ZStack {
                        Color.white.opacity(minOpacity)
                        if !reduceMotion {
                            TimelineView(.animation(paused: !isSweeping)) { context in
                                band(at: context.date)
                            }
                        }
                        Color.white.opacity(1 - intensity)
                    }
                    .frame(width: amountWidth)
                    .clipped()
                    Color.white
                }
                .padding(-maskOutset)
            }
            .overlay {
                if isActive {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(t("wallet__balance_updating"))
                        .accessibilityIdentifier("TotalBalanceUpdating")
                }
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

    /// The band travels from fully before the amount to fully past it, so each pass starts and ends off the digits.
    private func band(at date: Date) -> some View {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepDuration) / sweepDuration
        return LinearGradient(
            colors: [.clear, .white, .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: bandWidth)
        .offset(x: -bandWidth + phase * (amountWidth + bandWidth))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
