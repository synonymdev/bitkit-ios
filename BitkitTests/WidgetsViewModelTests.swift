@testable import Bitkit
import XCTest

@MainActor
final class WidgetsViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // `savedWidgets` is the user's home-screen layout; these tests delete it and persist
        // a synthetic set over the top.
        snapshotAppDefaults("savedWidgets")
        // Saving a widget also mirrors its options into the shared group.bitkit suite, which the
        // home-screen widget extension reads.
        snapshotAppGroupDefaults(
            "home_screen_news_widget_options_v1",
            "home_screen_price_widget_options_v1",
            "home_screen_blocks_widget_options_v1",
            "home_screen_weather_widget_options_v1"
        )
        UserDefaults.standard.removeObject(forKey: "savedWidgets")
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
