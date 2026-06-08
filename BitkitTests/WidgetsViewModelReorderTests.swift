@testable import Bitkit
import XCTest

/// Covers the drag-reorder core (`WidgetsViewModel.reorderWidgets`) that backs the home grid's
/// live drag-and-drop: moves must update the published order, persist, and reject invalid indices.
@MainActor
final class WidgetsViewModelReorderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
        super.tearDown()
    }

    /// Builds a deterministic three-widget set regardless of the default install set.
    private func makeViewModel(order: [WidgetType] = [.price, .blocks, .news]) -> WidgetsViewModel {
        let widgets = WidgetsViewModel()
        for type in WidgetType.allCases {
            widgets.deleteWidget(type)
        }
        for type in order {
            widgets.saveWidget(type)
        }
        XCTAssertEqual(widgets.savedWidgets.map(\.type), order, "precondition: known starting order")
        return widgets
    }

    func testReorder_MovesWidgetForwardAndUpdatesPublishedOrder() {
        let widgets = makeViewModel()
        widgets.reorderWidgets(from: 0, to: 2)
        XCTAssertEqual(widgets.savedWidgets.map(\.type), [.blocks, .news, .price])
    }

    func testReorder_MovesWidgetBackward() {
        let widgets = makeViewModel()
        widgets.reorderWidgets(from: 2, to: 0)
        XCTAssertEqual(widgets.savedWidgets.map(\.type), [.news, .price, .blocks])
    }

    func testReorder_Persists_ReflectedAfterReload() {
        let widgets = makeViewModel()
        widgets.reorderWidgets(from: 0, to: 2)

        let reloaded = WidgetsViewModel()
        XCTAssertEqual(reloaded.savedWidgets.map(\.type), [.blocks, .news, .price])
    }

    func testReorder_SameIndex_IsNoOp() {
        let widgets = makeViewModel()
        widgets.reorderWidgets(from: 1, to: 1)
        XCTAssertEqual(widgets.savedWidgets.map(\.type), [.price, .blocks, .news])
    }

    func testReorder_OutOfBoundsIndices_AreIgnored() {
        let widgets = makeViewModel()
        widgets.reorderWidgets(from: 5, to: 0)
        widgets.reorderWidgets(from: 0, to: 9)
        widgets.reorderWidgets(from: -1, to: 1)
        XCTAssertEqual(widgets.savedWidgets.map(\.type), [.price, .blocks, .news])
    }
}
