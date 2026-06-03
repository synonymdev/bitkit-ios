@testable import Bitkit
import XCTest

/// Locks in the contract that the News widget title can never be unselected:
/// - The edit screen always re-enables `showTitle`, even if a persisted config had it off.
/// - The edit list renders the title as a locked, always-checked static item, while
///   source/date stay deselectable toggles.
/// - `toggleOption` never flips the title.
@MainActor
final class NewsWidgetTitleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
        NewsViewModel.shared.widgetData = nil
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
        NewsViewModel.shared.widgetData = nil
        super.tearDown()
    }

    private func item(_ items: [WidgetEditItem], key: String) -> WidgetEditItem? {
        items.first { $0.key == key }
    }

    // MARK: - WidgetEditLogic

    /// Even if a previously-saved config disabled the title, opening the edit screen forces it
    /// back on so the widget always renders a headline.
    func testLoadCurrentOptions_ForcesShowTitleEnabled_EvenWhenPersistedFalse() {
        let widgets = WidgetsViewModel()
        widgets.stageOptions(
            NewsWidgetOptions(showDate: true, showTitle: false, showSource: false),
            for: .news
        )
        widgets.saveWidget(.news)

        let logic = WidgetEditLogic(widgetType: .news, widgetsViewModel: widgets)
        logic.loadCurrentOptions()

        XCTAssertTrue(logic.newsOptions.showTitle, "Title must always be enabled on load")
        // Other fields must be preserved as saved.
        XCTAssertTrue(logic.newsOptions.showDate)
        XCTAssertFalse(logic.newsOptions.showSource)
    }

    /// `toggleOption` must never disable the (static) title, but must still flip normal toggles.
    func testToggleOption_NeverDisablesTitle_ButTogglesOtherFields() {
        let widgets = WidgetsViewModel()
        let logic = WidgetEditLogic(widgetType: .news, widgetsViewModel: widgets)
        logic.newsOptions = NewsWidgetOptions(showDate: true, showTitle: true, showSource: true)

        let titleItem = WidgetEditItem(key: "showTitle", type: .staticItem, title: "Title", value: nil, isChecked: true)
        logic.toggleOption(titleItem)
        XCTAssertTrue(logic.newsOptions.showTitle, "Static title item must not be toggled off")

        let sourceItem = WidgetEditItem(key: "showSource", type: .toggleItem, title: "Source", value: nil, isChecked: true)
        logic.toggleOption(sourceItem)
        XCTAssertFalse(logic.newsOptions.showSource, "Source toggle must still flip")
    }

    // MARK: - WidgetEditItemFactory

    /// The title row is always a locked, checked static item — regardless of the stored
    /// `showTitle` value — while source and date remain deselectable toggles.
    func testNewsEditItems_TitleIsLockedAndAlwaysChecked() {
        let items = WidgetEditItemFactory.getNewsItems(
            newsViewModel: .shared,
            // Deliberately pass showTitle: false to prove the factory ignores it for the title.
            newsOptions: NewsWidgetOptions(showDate: true, showTitle: false, showSource: true)
        )

        let title = item(items, key: "showTitle")
        XCTAssertNotNil(title, "Title item must be present")
        XCTAssertEqual(title?.type, .staticItem, "Title must be a non-tappable static item")
        XCTAssertEqual(title?.isChecked, true, "Title must always render as checked")

        XCTAssertEqual(item(items, key: "showSource")?.type, .toggleItem, "Source must stay deselectable")
        XCTAssertEqual(item(items, key: "showDate")?.type, .toggleItem, "Date must stay deselectable")
    }
}
