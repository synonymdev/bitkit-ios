@testable import Bitkit
import XCTest

@MainActor
final class WidgetsViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
        super.tearDown()
    }

    func testSavingWidgetAfterEditingUnsavedOptionsDoesNotDuplicateAfterReload() {
        let widgets = WidgetsViewModel()
        widgets.deleteWidget(.suggestions)
        widgets.deleteWidget(.price)
        widgets.deleteWidget(.blocks)

        widgets.stageOptions(PriceWidgetOptions(selectedPair: "BTC/EUR", selectedPeriod: .oneWeek), for: .price)
        widgets.saveWidget(.price)

        let reloadedWidgets = WidgetsViewModel()
        let priceWidgets = reloadedWidgets.savedWidgets.filter { $0.type == .price }
        let options: PriceWidgetOptions = reloadedWidgets.getOptions(for: .price, as: PriceWidgetOptions.self)

        XCTAssertEqual(priceWidgets.count, 1)
        XCTAssertEqual(options, PriceWidgetOptions(selectedPair: "BTC/EUR", selectedPeriod: .oneWeek))
    }
}
