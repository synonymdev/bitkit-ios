@testable import Bitkit
import XCTest

/// Covers the home grid pairing algorithm (`widgetGridSlots`, extracted from `WidgetFlowLayout`):
/// wide items span the full width; consecutive smalls pair side by side at equal (max) height;
/// a lone trailing small — or a small immediately followed by a wide — takes the left column only.
final class WidgetGridLayoutTests: XCTestCase {
    private let width: CGFloat = 343
    private let spacing: CGFloat = 16
    private var columnWidth: CGFloat {
        (width - spacing) / 2
    } // 163.5

    /// Convenience runner with a constant-height provider.
    private func layout(_ isWide: [Bool], heights: [CGFloat]) -> (slots: [WidgetGridSlot], totalHeight: CGFloat) {
        widgetGridSlots(isWide: isWide, width: width, spacing: spacing) { index, _ in heights[index] }
    }

    func testEmpty_ProducesNoSlotsAndZeroHeight() {
        let result = widgetGridSlots(isWide: [], width: width, spacing: spacing) { _, _ in 0 }
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertEqual(result.totalHeight, 0)
    }

    func testSingleWide_SpansFullWidth() {
        let result = layout([true], heights: [100])
        XCTAssertEqual(result.slots, [WidgetGridSlot(index: 0, frame: CGRect(x: 0, y: 0, width: width, height: 100))])
        XCTAssertEqual(result.totalHeight, 100)
    }

    func testLoneSmall_TakesLeftColumn() {
        let result = layout([false], heights: [150])
        XCTAssertEqual(result.slots, [WidgetGridSlot(index: 0, frame: CGRect(x: 0, y: 0, width: columnWidth, height: 150))])
        XCTAssertEqual(result.totalHeight, 150)
    }

    func testTwoSmalls_PairSideBySideAtMaxHeight() {
        let result = layout([false, false], heights: [100, 160])
        XCTAssertEqual(result.slots, [
            WidgetGridSlot(index: 0, frame: CGRect(x: 0, y: 0, width: columnWidth, height: 160)),
            WidgetGridSlot(index: 1, frame: CGRect(x: columnWidth + spacing, y: 0, width: columnWidth, height: 160)),
        ])
        XCTAssertEqual(result.totalHeight, 160)
    }

    func testSmallFollowedByWide_SmallTakesLeftColumnThenWideOnNextRow() {
        let result = layout([false, true], heights: [100, 120])
        XCTAssertEqual(result.slots, [
            WidgetGridSlot(index: 0, frame: CGRect(x: 0, y: 0, width: columnWidth, height: 100)),
            WidgetGridSlot(index: 1, frame: CGRect(x: 0, y: 100 + spacing, width: width, height: 120)),
        ])
        XCTAssertEqual(result.totalHeight, 100 + spacing + 120)
    }

    func testThreeSmalls_FirstTwoPairThirdIsLone() {
        let result = layout([false, false, false], heights: [100, 100, 100])
        XCTAssertEqual(result.slots, [
            WidgetGridSlot(index: 0, frame: CGRect(x: 0, y: 0, width: columnWidth, height: 100)),
            WidgetGridSlot(index: 1, frame: CGRect(x: columnWidth + spacing, y: 0, width: columnWidth, height: 100)),
            WidgetGridSlot(index: 2, frame: CGRect(x: 0, y: 100 + spacing, width: columnWidth, height: 100)),
        ])
        XCTAssertEqual(result.totalHeight, 100 + spacing + 100)
    }

    func testWideThenSmallPair_StacksRows() {
        let result = layout([true, false, false], heights: [120, 90, 90])
        XCTAssertEqual(result.slots, [
            WidgetGridSlot(index: 0, frame: CGRect(x: 0, y: 0, width: width, height: 120)),
            WidgetGridSlot(index: 1, frame: CGRect(x: 0, y: 120 + spacing, width: columnWidth, height: 90)),
            WidgetGridSlot(index: 2, frame: CGRect(x: columnWidth + spacing, y: 120 + spacing, width: columnWidth, height: 90)),
        ])
        XCTAssertEqual(result.totalHeight, 120 + spacing + 90)
    }

    /// The height provider must be asked for the width each item is actually laid out at:
    /// full width for a wide item, column width for paired/lone smalls.
    func testHeightProvider_ReceivesResolvedWidthPerItem() {
        // Returning the proposed width as the height lets us assert which width was used.
        let result = widgetGridSlots(isWide: [true, false, false], width: width, spacing: spacing) { _, proposedWidth in
            proposedWidth
        }
        XCTAssertEqual(result.slots[0].frame.height, width) // wide → full width
        XCTAssertEqual(result.slots[1].frame.height, columnWidth) // paired small → column width
        XCTAssertEqual(result.slots[2].frame.height, columnWidth)
    }

    // MARK: - nearestWidgetSlot (drag targeting)

    /// Two smalls paired on the top row, a wide widget below — the layout from the bug report.
    /// Small row: y 0...192. Inter-row gap: 192...208. Wide row: y 208...328.
    private let dragFrames: [WidgetType: CGRect] = [
        .price: CGRect(x: 0, y: 0, width: 163.5, height: 192), // top-left small
        .news: CGRect(x: 179.5, y: 0, width: 163.5, height: 192), // top-right small
        .blocks: CGRect(x: 0, y: 208, width: 343, height: 120), // wide below
    ]

    func testNearestSlot_EmptyFrames_ReturnsNil() {
        XCTAssertNil(nearestWidgetSlot(at: CGPoint(x: 100, y: 100), frames: [:]))
    }

    func testNearestSlot_InsideLeftSmall_ReturnsLeftSmall() {
        XCTAssertEqual(nearestWidgetSlot(at: CGPoint(x: 80, y: 96), frames: dragFrames), .price)
    }

    func testNearestSlot_InsideRightSmall_ReturnsRightSmall() {
        XCTAssertEqual(nearestWidgetSlot(at: CGPoint(x: 260, y: 96), frames: dragFrames), .news)
    }

    /// The regression case: a point at the centre of the inter-row gap targets the wide row below,
    /// so dragging a top small straight down only needs to reach the gap centre — not a pixel-spot.
    func testNearestSlot_InGapCentre_TargetsWideBelow() {
        XCTAssertEqual(nearestWidgetSlot(at: CGPoint(x: 80, y: 200), frames: dragFrames), .blocks)
    }

    func testNearestSlot_AboveFirstRow_TargetsTopSlot() {
        XCTAssertEqual(nearestWidgetSlot(at: CGPoint(x: 80, y: -40), frames: dragFrames), .price)
    }

    func testNearestSlot_FarBelowLastRow_TargetsWide() {
        XCTAssertEqual(nearestWidgetSlot(at: CGPoint(x: 170, y: 500), frames: dragFrames), .blocks)
    }
}
