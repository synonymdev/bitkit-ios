import SwiftUI

struct HomeWidgetsView: View {
    @Environment(CalculatorInputManager.self) private var calculatorInput
    @EnvironmentObject var app: AppViewModel
    @Environment(KeyboardManager.self) private var keyboard
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    @Binding var isEditingWidgets: Bool

    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    /// Global frame of the (single) calculator widget card, reported via preference key.
    /// Used to compute how far to lift content so the focused calculator sits above the keypad.
    @State private var calculatorFrame: CGRect?
    @State private var didStartCalculatorDismissDrag = false
    @State private var focusedContentOffsetY: CGFloat = 0
    @State private var dragState = WidgetDragState()

    private static let focusAnimation = Animation.easeOut(duration: focusAnimationDuration)
    private static let focusAnimationDuration = 0.12
    private static let focusDismissDragMinimumDistance: CGFloat = 8

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

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
        ScrollViewReader { _ in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                        ForEach(gridRows) { row in
                            GridRow {
                                switch row {
                                case let .wide(widget):
                                    cell(widget)
                                        .gridCellColumns(2)
                                case let .pair(first, second):
                                    cell(first)
                                    if let second {
                                        cell(second)
                                    } else {
                                        Color.clear
                                    }
                                }
                            }
                        }
                    }
                    .id(visibleWidgets.map(\.id))
                    .environment(\.widgetDragState, dragState)
                    // Catch-all so drops that land in a gap are still accepted (the live
                    // reorder already happened on hover); avoids the snap-back animation.
                    .onDrop(of: [.utf8PlainText], delegate: WidgetGridDropDelegate(dragState: dragState))

                    CustomButton(
                        title: t("widgets__add"),
                        variant: .tertiary,
                        icon: Image("plus")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 16, height: 16)
                            .foregroundColor(.white80)
                    ) {
                        calculatorInput.dismiss()

                        if app.hasSeenWidgetsIntro {
                            sheets.showSheet(.widgets, data: WidgetsConfig(initialRoute: .list))
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
            .overlay(alignment: .bottom) {
                if calculatorInput.isPresented {
                    CalculatorNumberPadBar()
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeOut(duration: 0.14), value: calculatorInput.isPresented)
            .onChange(of: calculatorInput.isPresented) { _, isPresented in
                if isPresented {
                    focusCalculator()
                } else {
                    setFocusedContentOffsetY(0)
                }
            }
            .onPreferenceChange(CalculatorWidgetFramePreferenceKey.self) { frame in
                calculatorFrame = frame
            }
            .onDisappear {
                calculatorInput.dismiss()
            }
        }
    }

    private func focusCalculator() {
        guard let frame = calculatorFrame else {
            setFocusedContentOffsetY(0)
            return
        }
        let keypadTop = UIScreen.main.bounds.height - CalculatorNumberPadBar.height
        let desiredMaxY = keypadTop - 16
        let overlap = frame.maxY - desiredMaxY
        setFocusedContentOffsetY(overlap > 0 ? -overlap : 0)
    }

    private func handleWidgetsPageDragChanged(_ value: DragGesture.Value) {
        if calculatorInput.isPresented || didStartCalculatorDismissDrag {
            didStartCalculatorDismissDrag = true
            calculatorInput.dismiss()
        }
    }

    private func setFocusedContentOffsetY(_ value: CGFloat) {
        guard abs(value - focusedContentOffsetY) > 1 else { return }

        withAnimation(Self.focusAnimation) {
            focusedContentOffsetY = value
        }
    }

    /// Resolved layout size for the grid. Calculator and suggestions are always wide
    /// regardless of the value stored on `SavedWidget`.
    private func displayedSize(for widget: Widget) -> WidgetSize {
        switch widget.type {
        case .suggestions: return .wide
        default: return widget.size
        }
    }

    /// A logical row in the home grid — either a single wide widget spanning both columns,
    /// or up to two small widgets paired side-by-side. Built by walking `visibleWidgets`
    /// in order; the second slot of a `pair` is `nil` if a small widget has no neighbour.
    private enum WidgetRow: Identifiable {
        case wide(Widget)
        case pair(Widget, Widget?)

        var id: String {
            switch self {
            case let .wide(w): return "wide-\(w.id.rawValue)"
            case let .pair(a, b): return "pair-\(a.id.rawValue)-\(b?.id.rawValue ?? "_")"
            }
        }
    }

    private var gridRows: [WidgetRow] {
        var result: [WidgetRow] = []
        var pendingSmall: Widget?

        for widget in visibleWidgets {
            if displayedSize(for: widget) == .wide {
                if let pending = pendingSmall {
                    result.append(.pair(pending, nil))
                    pendingSmall = nil
                }
                result.append(.wide(widget))
            } else if let pending = pendingSmall {
                result.append(.pair(pending, widget))
                pendingSmall = nil
            } else {
                pendingSmall = widget
            }
        }
        if let pending = pendingSmall {
            result.append(.pair(pending, nil))
        }
        return result
    }

    private func cell(_ widget: Widget) -> some View {
        rowContent(widget)
            .onDrop(
                of: [.utf8PlainText],
                delegate: WidgetCellDropDelegate(target: widget, dragState: dragState, reorder: reorder)
            )
    }

    /// Reorder by resolved type. Returns `true` if anything moved.
    @discardableResult
    fileprivate func reorder(from sourceType: WidgetType, to targetType: WidgetType) -> Bool {
        guard sourceType != targetType,
              let sourceIdx = widgets.savedWidgets.firstIndex(where: { $0.type == sourceType }),
              let destIdx = widgets.savedWidgets.firstIndex(where: { $0.type == targetType })
        else { return false }
        widgets.reorderWidgets(from: sourceIdx, to: destIdx)
        return true
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

/// Shared drag context for the home widget grid. The dragged widget's type is recorded when
/// the burger handle's drag starts (in `BaseWidget`) so drop delegates can reorder live on hover
/// without having to asynchronously load the item provider.
final class WidgetDragState {
    var draggingType: WidgetType?
}

private struct WidgetDragStateKey: EnvironmentKey {
    static let defaultValue = WidgetDragState()
}

extension EnvironmentValues {
    var widgetDragState: WidgetDragState {
        get { self[WidgetDragStateKey.self] }
        set { self[WidgetDragStateKey.self] = newValue }
    }
}

/// Per-cell delegate that reorders **live** as the dragged widget hovers over this cell.
/// This makes drop position robust — you never need to release in the exact gap, because the
/// array is already reordered by the time you let go.
private struct WidgetCellDropDelegate: DropDelegate {
    let target: Widget
    let dragState: WidgetDragState
    let reorder: (WidgetType, WidgetType) -> Bool

    func dropEntered(info _: DropInfo) {
        guard let source = dragState.draggingType, source != target.type else { return }
        if reorder(source, target.type) {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragState.draggingType = nil
        return true
    }
}

/// Catch-all delegate on the grid itself: accepts drops that land in a gap (no reorder needed —
/// the cell delegates already moved things on hover) and clears the drag state.
private struct WidgetGridDropDelegate: DropDelegate {
    let dragState: WidgetDragState

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragState.draggingType = nil
        return true
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
