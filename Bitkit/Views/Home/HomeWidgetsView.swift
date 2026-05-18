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
    @State private var calculatorFrame: CGRect = .zero

    private var bottomPadding: CGFloat {
        // Keep the calculator widget fully scrollable above the keyboard.
        let inset = keyboard.height + ScreenLayout.bottomSpacing
        return keyboard.isPresented ? inset : ScreenLayout.bottomPaddingWithSafeArea
    }

    /// Widgets to display; suggestions widget is hidden when it would show no cards (unless editing).
    private var widgetsToShow: [Widget] {
        widgets.savedWidgets.filter { widget in
            if widget.type != .suggestions { return true }
            if isEditingWidgets { return true }
            return !Suggestions.visibleCards(wallet: wallet, app: app, settings: settings, suggestionsManager: suggestionsManager).isEmpty
        }
    }

    private var visibleWidgets: [Widget] {
        guard calculatorInput.isPresented,
              let calculatorIndex = widgetsToShow.firstIndex(where: { $0.type == .calculator })
        else {
            return widgetsToShow
        }

        return Array(widgetsToShow.prefix(through: calculatorIndex))
    }

    private var shouldAnchorCalculator: Bool {
        calculatorInput.isPresented && widgetsToShow.first?.type == .calculator
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
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

                if !calculatorInput.isPresented {
                    CustomButton(title: t("widgets__add"), variant: .tertiary) {
                        calculatorInput.dismiss()

                        if app.hasSeenWidgetsIntro {
                            navigation.navigate(.widgetsList)
                        } else {
                            navigation.navigate(.widgetsIntro)
                        }
                    }
                    .padding(.top, 16)
                    .accessibilityIdentifier("WidgetsAdd")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, ScreenLayout.topPaddingWithSafeArea)
            .padding(.bottom, bottomPadding)
            .padding(.horizontal)
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
            DragGesture(minimumDistance: 8).onChanged { _ in
                if calculatorInput.isPresented {
                    calculatorInput.dismiss()
                }
            }
        )
        // Dismiss (calculator widget) keyboard when scrolling
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(CalculatorWidgetFramePreferenceKey.self) { frame in
            if let frame, !calculatorInput.isPresented {
                calculatorFrame = frame
            }
        }
    }

    private var anchoredCalculatorTopPadding: CGFloat {
        guard shouldAnchorCalculator else { return 0 }

        let bottomInset = windowSafeAreaInsets.bottom > 0 ? windowSafeAreaInsets.bottom : 16
        let numberPadTop = UIScreen.main.bounds.height - bottomInset - NumberPad.contentHeight
        let preferredGap: CGFloat = 16
        let calculatorHeight = calculatorFrame.height > 0 ? calculatorFrame.height : 144
        return max(0, numberPadTop - ScreenLayout.topPaddingWithSafeArea - calculatorHeight - preferredGap)
    }

    @ViewBuilder
    private func rowContent(_ widget: Widget) -> some View {
        if widget.type == .calculator {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: anchoredCalculatorTopPadding)
                    .animation(.easeInOut(duration: 0.2), value: anchoredCalculatorTopPadding)

                widget.view(
                    widgetsViewModel: widgets,
                    isEditing: isEditingWidgets,
                    onEditingEnd: { withAnimation { isEditingWidgets = false } }
                )
                .id(widget.id)
                .trackCalculatorWidgetFrame()
            }
        } else {
            widget.view(
                widgetsViewModel: widgets,
                isEditing: isEditingWidgets,
                onEditingEnd: { withAnimation { isEditingWidgets = false } }
            )
            .id(widget.id)
            .simultaneousGesture(
                TapGesture().onEnded {
                    calculatorInput.dismiss()
                }
            )
        }
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
