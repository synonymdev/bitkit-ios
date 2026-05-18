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
    @State private var calculatorContentOffset: CGFloat = 0
    @State private var isScrollLocked = false

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

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                DraggableList(
                    widgetsToShow,
                    id: \.id,
                    enableDrag: isEditingWidgets,
                    itemHeight: 80,
                    onReorder: { sourceIndex, destinationIndex in
                        widgets.reorderWidgets(from: sourceIndex, to: destinationIndex)
                    }
                ) { widget in
                    rowContent(widget)
                }
                .id(widgetsToShow.map(\.id))

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
            .offset(y: -calculatorContentOffset)
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
        .scrollDisabled(isScrollLocked)
        .mask {
            calculatorContentMask
        }
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
        .onChange(of: calculatorInput.activeInput) {
            guard calculatorInput.activeInput != nil else {
                calculatorContentOffset = 0
                isScrollLocked = false
                return
            }

            calculatorContentOffset = focusedCalculatorOffset()
            isScrollLocked = true
        }
    }

    @ViewBuilder
    private var calculatorContentMask: some View {
        if calculatorInput.isPresented {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: ScreenLayout.topPaddingWithSafeArea + 8)

                Color.white
            }
        } else {
            Color.white
        }
    }

    private func focusedCalculatorOffset() -> CGFloat {
        let bottomInset = windowSafeAreaInsets.bottom > 0 ? windowSafeAreaInsets.bottom : 16
        let numberPadTop = UIScreen.main.bounds.height - bottomInset - NumberPad.contentHeight
        let preferredGap: CGFloat = 16
        let focusedBottom = numberPadTop - preferredGap
        let focusedTop = max(ScreenLayout.topPaddingWithSafeArea + 8, focusedBottom - calculatorFrame.height)
        return max(0, calculatorFrame.minY - focusedTop)
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
