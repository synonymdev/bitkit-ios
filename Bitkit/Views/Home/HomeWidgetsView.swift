import SwiftUI

struct HomeWidgetsView: View {
    @Environment(CalculatorInputManager.self) private var calculatorInput
    @EnvironmentObject var app: AppViewModel
    @Environment(KeyboardManager.self) private var keyboard
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    @Binding var isEditingWidgets: Bool

    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    @State private var calculatorFrame: CGRect?
    @State private var didApplyFirstCalculatorFocusPadding = false
    @State private var didStartCalculatorDismissDrag = false
    @StateObject private var focusAdjustmentState = CalculatorFocusAdjustmentState()
    @State private var focusedContentOffsetY: CGFloat = 0
    @State private var firstCalculatorTopPadding: CGFloat = 0
    @State private var numberPadFrame: CGRect?

    private static let focusAnimation = Animation.easeOut(duration: focusAnimationDuration)
    private static let focusAnimationDuration = 0.12
    private static let focusDismissDragMinimumDistance: CGFloat = 8
    private static let maxFocusAdjustmentPasses = 4
    private static let numberPadEstimatedHeight = 8 + NumberPad.contentHeight + (windowSafeAreaInsets.bottom > 0 ? windowSafeAreaInsets.bottom : 16)

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    private var bottomPadding: CGFloat {
        // Keep the calculator widget fully scrollable above the keyboard.
        let inset = keyboard.height + ScreenLayout.bottomSpacing
        return keyboard.isPresented ? inset : ScreenLayout.bottomPaddingWithSafeArea
    }

    private var isCalculatorFirst: Bool {
        widgetsToShow.first?.type == .calculator
    }

    /// Widgets to display; suggestions widget is hidden when it would show no cards (unless editing).
    private var widgetsToShow: [Widget] {
        widgets.savedWidgets.filter { widget in
            if widget.type != .suggestions { return true }
            if isEditingWidgets { return true }
            return !Suggestions.visibleCards(
                wallet: wallet,
                app: app,
                settings: settings,
                suggestionsManager: suggestionsManager,
                isPaykitUIEnabled: isPaykitUIActive
            ).isEmpty
        }
    }

    private var visibleWidgets: [Widget] {
        widgetsToShow
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if isCalculatorFirst {
                        Color.clear
                            .frame(height: firstCalculatorTopPadding)
                    }

                    DraggableList(
                        visibleWidgets,
                        id: \.id,
                        enableDrag: isEditingWidgets && !calculatorInput.isPresented,
                        itemHeight: 80,
                        onReorder: { sourceIndex, destinationIndex in
                            widgets.reorderWidgets(from: sourceIndex, to: destinationIndex)
                        }
                    ) { widget in
                        rowContent(widget)
                    }
                    .id(visibleWidgets.map(\.id))

                    CustomButton(title: t("widgets__add"), variant: .tertiary) {
                        calculatorInput.dismiss()

                        if app.hasSeenWidgetsIntro {
                            navigation.navigate(.widgetsList)
                        } else {
                            navigation.navigate(.widgetsIntro)
                        }
                    }
                    .padding(.top, 16)
                    .opacity(calculatorInput.isPresented ? 0 : 1)
                    .allowsHitTesting(!calculatorInput.isPresented)
                    .accessibilityHidden(calculatorInput.isPresented)
                    .accessibilityIdentifier("WidgetsAdd")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, ScreenLayout.topPaddingWithSafeArea)
                .padding(.bottom, bottomPadding)
                .padding(.horizontal)
                .offset(y: focusedContentOffsetY)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            calculatorInput.dismiss()
                        }
                }
            }
            .scrollDisabled(calculatorInput.isPresented)
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.focusDismissDragMinimumDistance)
                    .onChanged(handleWidgetsPageDragChanged)
                    .onEnded { _ in
                        didStartCalculatorDismissDrag = false
                    },
                including: calculatorInput.isPresented || didStartCalculatorDismissDrag ? .all : .none
            )
            // Dismiss (calculator widget) keyboard when scrolling
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: calculatorInput.isPresented) { _, isPresented in
                if isPresented {
                    startFocusedCalculatorTransition(proxy)
                } else {
                    setFocusedContentOffsetY(0)
                    setFirstCalculatorTopPadding(0)
                    finishFocusedCalculatorDismissal()
                }
            }
            .onPreferenceChange(CalculatorWidgetFramePreferenceKey.self) { frame in
                calculatorFrame = frame
            }
            .onPreferenceChange(CalculatorNumberPadFramePreferenceKey.self) { frame in
                numberPadFrame = frame
                settleFocusedCalculator(proxy, numberPadFrame: frame)
            }
            .onDisappear {
                calculatorInput.dismiss()
            }
        }
    }

    private func startFocusedCalculatorTransition(_ proxy: ScrollViewProxy) {
        if focusAdjustmentState.hasStartedPresentation {
            if isCalculatorFirst, !didApplyFirstCalculatorFocusPadding {
                applyFirstCalculatorFocusPadding(proxy)
            }

            return
        }

        resetFocusAdjustment()
        focusAdjustmentState.hasStartedPresentation = true

        if isCalculatorFirst {
            setFocusedContentOffsetY(0)
            applyFirstCalculatorFocusPadding(proxy)
            return
        }

        if firstCalculatorTopPadding > 0 {
            setFirstCalculatorTopPadding(0)
        }

        settleFocusedCalculator(proxy)
    }

    private func handleWidgetsPageDragChanged(_ value: DragGesture.Value) {
        if calculatorInput.isPresented || didStartCalculatorDismissDrag {
            didStartCalculatorDismissDrag = true
            calculatorInput.dismiss()
        }
    }

    private func applyFirstCalculatorFocusPadding(_ proxy: ScrollViewProxy) {
        guard let bottomGap = focusedNumberPadBottomGap(numberPadFrame: numberPadFrame) else { return }

        didApplyFirstCalculatorFocusPadding = true
        setFirstCalculatorTopPadding(max(0, bottomGap))
    }

    private func settleFocusedCalculator(
        _ proxy: ScrollViewProxy,
        numberPadFrame proposedNumberPadFrame: CGRect? = nil
    ) {
        guard calculatorInput.isPresented else { return }

        let currentNumberPadFrame = proposedNumberPadFrame ?? numberPadFrame

        if isCalculatorFirst {
            if !didApplyFirstCalculatorFocusPadding {
                startFocusedCalculatorTransition(proxy)
                return
            }

            settleFirstCalculatorStack(numberPadFrame: currentNumberPadFrame)
            return
        } else if firstCalculatorTopPadding > 0 {
            setFirstCalculatorTopPadding(0)
        }

        guard let bottomGap = focusedNumberPadBottomGap(numberPadFrame: currentNumberPadFrame),
              !focusAdjustmentState.isAdjusting
        else { return }

        guard abs(bottomGap) > 1 else {
            focusAdjustmentState.resetCorrection()
            return
        }

        guard focusAdjustmentState.passes < Self.maxFocusAdjustmentPasses else { return }

        adjustFocusedCalculatorByBottomGap(bottomGap, numberPadFrame: currentNumberPadFrame)
    }

    private func settleFirstCalculatorStack(numberPadFrame: CGRect?) {
        guard let bottomGap = focusedNumberPadBottomGap(numberPadFrame: numberPadFrame) else { return }
        guard abs(bottomGap) > 1 else { return }
        guard shouldApplyFocusAdjustment(for: numberPadFrame) else { return }

        setFirstCalculatorTopPadding(max(0, firstCalculatorTopPadding + bottomGap))
    }

    private func focusedNumberPadBottomGap(numberPadFrame: CGRect?) -> CGFloat? {
        guard let numberPadFrame else { return nil }

        if numberPadFrame.height >= Self.numberPadEstimatedHeight - 1 {
            return focusBottomY - numberPadFrame.maxY
        }

        if numberPadFrame.height >= NumberPad.contentHeight - 1 {
            return numberPadButtonsBottomY - numberPadFrame.maxY
        }

        return nil
    }

    private func adjustFocusedCalculatorByBottomGap(_ bottomGap: CGFloat, numberPadFrame: CGRect?) {
        guard shouldApplyFocusAdjustment(for: numberPadFrame) else { return }

        focusAdjustmentState.delta = (focusAdjustmentState.delta ?? 0) + bottomGap
        focusAdjustmentState.passes += 1
        focusAdjustmentState.isAdjusting = true
        setFocusedContentOffsetY(focusedContentOffsetY + bottomGap)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusAnimationDuration + 0.03) {
            guard calculatorInput.isPresented, !isCalculatorFirst else { return }
            focusAdjustmentState.isAdjusting = false
        }
    }

    private func shouldApplyFocusAdjustment(for numberPadFrame: CGRect?) -> Bool {
        guard let numberPadFrame else { return true }

        let maxY = numberPadFrame.maxY
        if let lastAdjustedNumberPadMaxY = focusAdjustmentState.lastAdjustedNumberPadMaxY, abs(lastAdjustedNumberPadMaxY - maxY) <= 1 {
            return false
        }

        focusAdjustmentState.lastAdjustedNumberPadMaxY = maxY
        return true
    }

    private func resetFocusAdjustment() {
        focusAdjustmentState.reset()
    }

    private func finishFocusedCalculatorDismissal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusAnimationDuration + 0.05) {
            guard !calculatorInput.isPresented else { return }

            calculatorFrame = nil
            didApplyFirstCalculatorFocusPadding = false
            numberPadFrame = nil
            resetFocusAdjustment()
        }
    }

    private func setFirstCalculatorTopPadding(_ value: CGFloat) {
        guard abs(value - firstCalculatorTopPadding) > 1 else { return }

        withAnimation(Self.focusAnimation) {
            firstCalculatorTopPadding = value
        }
    }

    private func setFocusedContentOffsetY(_ value: CGFloat) {
        guard abs(value - focusedContentOffsetY) > 1 else { return }

        withAnimation(Self.focusAnimation) {
            focusedContentOffsetY = value
        }
    }

    private var focusBottomY: CGFloat {
        UIScreen.main.bounds.height
    }

    private var numberPadButtonsBottomY: CGFloat {
        focusBottomY - (windowSafeAreaInsets.bottom > 0 ? windowSafeAreaInsets.bottom : 16)
    }

    @ViewBuilder
    private func rowContent(_ widget: Widget) -> some View {
        if widget.type == .calculator {
            widget.view(
                widgetsViewModel: widgets,
                isEditing: isEditingWidgets,
                onEditingEnd: { withAnimation { isEditingWidgets = false } }
            )
            .id(widget.id)
            .trackCalculatorWidgetFrame()
        } else {
            let content = widget.view(
                widgetsViewModel: widgets,
                isEditing: isEditingWidgets,
                onEditingEnd: { withAnimation { isEditingWidgets = false } }
            )
            .id(widget.id)

            if calculatorInput.isPresented {
                ZStack {
                    content
                        .allowsHitTesting(false)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            calculatorInput.dismiss()
                        }
                }
            } else {
                content
            }
        }
    }
}

private final class CalculatorFocusAdjustmentState: ObservableObject {
    var delta: CGFloat?
    var hasStartedPresentation = false
    var isAdjusting = false
    var lastAdjustedNumberPadMaxY: CGFloat?
    var passes = 0

    func reset() {
        delta = nil
        hasStartedPresentation = false
        isAdjusting = false
        lastAdjustedNumberPadMaxY = nil
        passes = 0
    }

    func resetCorrection() {
        delta = nil
        lastAdjustedNumberPadMaxY = nil
        passes = 0
    }
}

private struct CalculatorWidgetFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private extension View {
    func trackCalculatorWidgetFrame() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CalculatorWidgetFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        }
    }
}
