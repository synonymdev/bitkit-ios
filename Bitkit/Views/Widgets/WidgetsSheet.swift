import SwiftUI

enum WidgetsRoute: Hashable {
    case list
    case preview(WidgetType)
    case edit(WidgetType)
}

struct WidgetsConfig {
    let initialRoute: WidgetsRoute

    init(initialRoute: WidgetsRoute = .list) {
        self.initialRoute = initialRoute
    }
}

struct WidgetsSheetItem: SheetItem {
    let id: SheetID = .widgets
    let size: SheetSize = .large
    let initialRoute: WidgetsRoute

    init(initialRoute: WidgetsRoute = .list) {
        self.initialRoute = initialRoute
    }
}

struct WidgetsSheet: View {
    @State private var navigationPath: [WidgetsRoute] = []
    let config: WidgetsSheetItem

    var body: some View {
        Sheet(id: .widgets, data: config, backgroundColor: .gray7) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: WidgetsRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: WidgetsRoute) -> some View {
        switch route {
        case .list:
            WidgetsListSheetView(navigationPath: $navigationPath)
        case let .preview(type):
            WidgetPreviewSheetView(type: type, navigationPath: $navigationPath)
        case let .edit(type):
            WidgetEditSheetView(type: type, navigationPath: $navigationPath)
        }
    }
}
