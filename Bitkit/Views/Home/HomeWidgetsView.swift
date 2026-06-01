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
    /// Frame of each visible widget cell in the grid's coordinate space, used by the drop delegate
    /// to resolve which slot a drag point targets.
    @State private var slotFrames: [WidgetType: CGRect] = [:]

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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetFlowLayout(spacing: 16) {
                    ForEach(visibleWidgets) { widget in
                        cell(widget)
                            .layoutValue(key: WidgetIsWideKey.self, value: displayedSize(for: widget) == .wide)
                    }
                }
                .environment(\.widgetDragState, dragState)
                .coordinateSpace(name: widgetGridCoordinateSpace)
                // Single grid-level drop target: it owns reorder targeting based on the finger's
                // absolute position over the grid (covering inter-row gaps), and accepts drops
                // anywhere so there's no snap-back.
                .onDrop(
                    of: [.utf8PlainText],
                    delegate: WidgetGridDropDelegate(dragState: dragState, frames: slotFrames, reorder: reorder)
                )
                .onPreferenceChange(WidgetSlotFramesKey.self) { slotFrames = $0 }

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

    /// Resolved layout size for the grid. Suggestions is always wide regardless of the value
    /// stored on `SavedWidget`
    private func displayedSize(for widget: Widget) -> WidgetSize {
        switch widget.type {
        case .suggestions: return .wide
        default: return widget.size
        }
    }

    private func cell(_ widget: Widget) -> some View {
        rowContent(widget)
            .trackWidgetSlotFrame(widget.type)
    }

    /// Reorder by resolved type. Returns `true` if anything moved.
    @discardableResult
    fileprivate func reorder(from sourceType: WidgetType, to targetType: WidgetType) -> Bool {
        guard sourceType != targetType,
              let sourceIdx = widgets.savedWidgets.firstIndex(where: { $0.type == sourceType }),
              let destIdx = widgets.savedWidgets.firstIndex(where: { $0.type == targetType })
        else { return false }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            widgets.reorderWidgets(from: sourceIdx, to: destIdx)
        }
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
    /// The last slot type the drag reordered onto, so repeated drop updates only act on a change.
    var lastTarget: WidgetType?
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

/// The single grid-level drop delegate. Reorder targeting is **location-based**: on every drop
/// update it resolves which slot the finger is over (or nearest to, covering inter-row gaps) from
/// the published cell `frames`, and reorders the dragged widget onto that slot. Because targeting
/// is by absolute position and `reorder` is idempotent (a no-op when source == target), repeated
/// updates self-correct instead of oscillating the way per-cell `dropEntered` did.
private struct WidgetGridDropDelegate: DropDelegate {
    let dragState: WidgetDragState
    let frames: [WidgetType: CGRect]
    let reorder: (WidgetType, WidgetType) -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let source = dragState.draggingType,
              let target = nearestWidgetSlot(at: info.location, frames: frames),
              target != source,
              target != dragState.lastTarget
        else { return DropProposal(operation: .move) }

        if reorder(source, target) {
            dragState.lastTarget = target
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragState.draggingType = nil
        dragState.lastTarget = nil
        return true
    }
}

private struct WidgetIsWideKey: LayoutValueKey {
    static let defaultValue = false
}

/// Two-column flow layout for the home widget grid. Wide widgets span the full width on their own
/// line; consecutive small widgets pair up side by side (a lone trailing small occupies the left
/// column). Children are flat and individually identified, so reordering animates as smooth moves
/// when the mutation is wrapped in `withAnimation`.
private struct WidgetFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let height = walk(subviews: subviews, width: width) { _, _, _ in }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        _ = walk(subviews: subviews, width: bounds.width) { subview, origin, size in
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
    }

    /// Walks the subviews applying the pairing rule, invoking `place` for each placed subview and
    /// returning the total content height. Delegates the geometry to the pure `widgetGridSlots`
    /// helper so the pairing rule can be unit-tested without SwiftUI's opaque `Subviews`.
    private func walk(
        subviews: Subviews,
        width: CGFloat,
        place: (LayoutSubview, CGPoint, CGSize) -> Void
    ) -> CGFloat {
        let isWide = (0 ..< subviews.count).map { subviews[$0][WidgetIsWideKey.self] }
        let result = widgetGridSlots(isWide: isWide, width: width, spacing: spacing) { index, proposedWidth in
            subviews[index].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil)).height
        }
        for slot in result.slots {
            place(subviews[slot.index], slot.frame.origin, slot.frame.size)
        }
        return result.totalHeight
    }
}

/// A placed widget in the home grid: the subview's index and its frame within the grid's bounds.
struct WidgetGridSlot: Equatable {
    let index: Int
    let frame: CGRect
}

func widgetGridSlots(
    isWide: [Bool],
    width: CGFloat,
    spacing: CGFloat,
    height: (_ index: Int, _ proposedWidth: CGFloat) -> CGFloat
) -> (slots: [WidgetGridSlot], totalHeight: CGFloat) {
    let columnWidth = (width - spacing) / 2
    var slots: [WidgetGridSlot] = []
    var y: CGFloat = 0
    var index = 0

    while index < isWide.count {
        if isWide[index] {
            let h = height(index, width)
            slots.append(WidgetGridSlot(index: index, frame: CGRect(x: 0, y: y, width: width, height: h)))
            y += h + spacing
            index += 1
        } else if index + 1 < isWide.count, !isWide[index + 1] {
            let h = max(height(index, columnWidth), height(index + 1, columnWidth))
            slots.append(WidgetGridSlot(index: index, frame: CGRect(x: 0, y: y, width: columnWidth, height: h)))
            slots.append(WidgetGridSlot(index: index + 1, frame: CGRect(x: columnWidth + spacing, y: y, width: columnWidth, height: h)))
            y += h + spacing
            index += 2
        } else {
            let h = height(index, columnWidth)
            slots.append(WidgetGridSlot(index: index, frame: CGRect(x: 0, y: y, width: columnWidth, height: h)))
            y += h + spacing
            index += 1
        }
    }

    return (slots, max(0, y - spacing))
}

/// Resolves which widget slot a drag point targets, given each visible widget's frame in the grid's
/// coordinate space. Picks the nearest slot by rectangle distance — zero when the point is inside a
/// frame — breaking ties on horizontal distance and then biasing toward the lower slot, so a point
/// at the centre of an inter-row gap targets the row below (this is what makes dragging a small from
/// the top row down past a wide widget easy). Returns nil only when there are no frames.
func nearestWidgetSlot(at point: CGPoint, frames: [WidgetType: CGRect]) -> WidgetType? {
    frames.min { lhs, rhs in
        slotDistanceKey(point, lhs.value) < slotDistanceKey(point, rhs.value)
    }?.key
}

/// Sort key for `nearestWidgetSlot`: vertical band distance, then horizontal band distance, then
/// `-minY` so a lower slot (larger minY) wins on an exact tie — biasing gap drops downward.
private func slotDistanceKey(_ point: CGPoint, _ rect: CGRect) -> (CGFloat, CGFloat, CGFloat) {
    (
        axisDistance(point.y, rect.minY, rect.maxY),
        axisDistance(point.x, rect.minX, rect.maxX),
        -rect.minY
    )
}

/// Distance from `value` to the closed interval `[min, max]`; zero when inside.
private func axisDistance(_ value: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
    if value < min { return min - value }
    if value > max { return value - max }
    return 0
}

/// Coordinate space shared by the grid's `.onDrop` (so `DropInfo.location` is grid-relative) and the
/// per-cell frame preferences, so both share one origin.
private let widgetGridCoordinateSpace = "widgetGrid"

/// Collects each visible widget cell's frame, keyed by type, for the drop delegate's hit-testing.
private struct WidgetSlotFramesKey: PreferenceKey {
    static let defaultValue: [WidgetType: CGRect] = [:]

    static func reduce(value: inout [WidgetType: CGRect], nextValue: () -> [WidgetType: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Reports this cell's frame in the grid coordinate space, keyed by widget type.
    func trackWidgetSlotFrame(_ type: WidgetType) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WidgetSlotFramesKey.self,
                    value: [type: proxy.frame(in: .named(widgetGridCoordinateSpace))]
                )
            }
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
