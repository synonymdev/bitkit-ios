import SwiftUI
import WidgetKit

// MARK: - Widget Bundle

@main
struct BitkitWidgetBundle: WidgetBundle {
    var body: some Widget {
        BitkitFactsWidget()
        BitkitBlocksWidget()
    }
}
