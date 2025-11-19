import SwiftUI

// MoneyStack - Stacked display with toggle functionality, optional eye icon and swipe gestures
struct MoneyStack: View {
    let sats: Int
    var prefix: String?
    var showSymbol: Bool = false
    var showEyeIcon: Bool = false
    var enableSwipeGesture: Bool = false

    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel

    // MARK: - Constants

    private let springAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if currency.primaryDisplay == .bitcoin {
                MoneyText(
                    sats: sats,
                    unitType: .secondary,
                    size: .caption,
                    symbol: true,
                    color: .textSecondary,
                    testIdentifier: "MoneyText"
                )
                .contentTransition(.numericText())
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 1.5, anchor: .topLeading))
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("TotalBalance-secondary")

                HStack {
                    MoneyText(
                        sats: sats,
                        unitType: .primary,
                        size: .display,
                        symbol: showSymbol,
                        prefix: prefix,
                        color: .textPrimary,
                        testIdentifier: "MoneyText"
                    )
                    .contentTransition(.numericText())

                    Spacer()

                    if showEyeIcon && settings.hideBalance {
                        eyeIconButton
                    }
                }
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.5, anchor: .topLeading))
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("TotalBalance-primary")
            } else {
                MoneyText(
                    sats: sats,
                    unitType: .secondary,
                    size: .caption,
                    symbol: true,
                    color: .textSecondary,
                    testIdentifier: "MoneyText"
                )
                .contentTransition(.numericText())
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 1.5, anchor: .topLeading))
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("TotalBalance-secondary")

                HStack {
                    MoneyText(
                        sats: sats,
                        unitType: .primary,
                        size: .display,
                        symbol: true,
                        prefix: prefix,
                        color: .textPrimary,
                        testIdentifier: "MoneyText"
                    )
                    .contentTransition(.numericText())

                    Spacer()

                    if showEyeIcon && settings.hideBalance {
                        eyeIconButton
                    }
                }
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.5, anchor: .topLeading))
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("TotalBalance-primary")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TotalBalance")
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(springAnimation) {
                currency.togglePrimaryDisplay()
            }
            Haptics.play(.medium)
        }
        .animation(springAnimation, value: currency.primaryDisplay)
        .conditionalGesture(enableSwipeGesture) {
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    let horizontalAmount = value.translation.width
                    let verticalAmount = value.translation.height

                    // Only trigger if horizontal swipe is more significant than vertical
                    if abs(horizontalAmount) > abs(verticalAmount) {
                        withAnimation(springAnimation) {
                            settings.hideBalance.toggle()
                        }
                        Haptics.play(.medium)
                    }
                }
        }
        .animation(enableSwipeGesture ? springAnimation : nil, value: settings.hideBalance)
    }
}

// MARK: - Helper Views

private extension MoneyStack {
    var eyeIconButton: some View {
        Button(action: revealBalance) {
            Image("eye")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.textPrimary)
        }
        .accessibilityIdentifier("ShowBalance")
        .padding(.leading, 8)
    }
}

// MARK: - Helper Methods

private extension MoneyStack {
    func revealBalance() {
        withAnimation(springAnimation) {
            settings.hideBalance = false
        }
        Haptics.play(.medium)
    }
}

// MARK: - Helper View Modifier

extension View {
    @ViewBuilder
    func conditionalGesture(_ condition: Bool, gesture: () -> some Gesture) -> some View {
        if condition {
            self.gesture(gesture())
        } else {
            self
        }
    }
}

// MARK: - Preview Helpers

private extension MoneyStack {
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
            // Large amounts to show dramatic transitions
            MoneyStack(sats: 1_234_567_890, prefix: "+", showSymbol: false)
                .environmentObject(MoneyStack.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD"))
                .environmentObject(MoneyStack.previewSettingsVM())

            // With symbol and different amount
            MoneyStack(sats: 987_654_321, prefix: "-", showSymbol: true)
                .environmentObject(MoneyStack.previewCurrencyVM(primaryDisplay: .fiat, currency: "EUR"))
                .environmentObject(MoneyStack.previewSettingsVM())

            // Medium amount with eye icon
            MoneyStack(sats: 456_789_123, showEyeIcon: true)
                .environmentObject(MoneyStack.previewCurrencyVM(primaryDisplay: .bitcoin, currency: "USD", displayUnit: .classic))
                .environmentObject(MoneyStack.previewSettingsVM(hideBalance: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.top)
    }
    .preferredColorScheme(.dark)
}
