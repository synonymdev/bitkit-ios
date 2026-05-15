import Foundation

/// Options for configuring the in-app and home-screen news widgets (shared via App Group).
struct NewsWidgetOptions: Codable, Equatable {
    var showDate: Bool = true
    var showTitle: Bool = true
    var showSource: Bool = true

    init(showDate: Bool = true, showTitle: Bool = true, showSource: Bool = true) {
        self.showDate = showDate
        self.showTitle = showTitle
        self.showSource = showSource
    }
}
