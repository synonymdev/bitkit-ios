import SwiftUI

enum Route: Hashable {
    case savingsWallet
    case spendingWallet
    case activityList
    case activityDetail(Activity)
    case activityExplorer(Activity)
    case profile
    case widgetsIntro
    case widgetsList
    case widgetDetail(WidgetType)
    case widgetEdit(WidgetType)
    case settings
    case transferIntro
    case fundingOptions
    case savingsIntro
    case savingsAvailability
    // Add other distinct screens
}

@MainActor
class NavigationViewModel: ObservableObject {
    // Drawer menu
    @Published var activeDrawerMenuItem: DrawerMenuItem = .wallet

    @Published var path: [Route] = []

    var currentRoute: Route? {
        path.last
    }

    func navigate(_ screen: Route) {
        path.append(screen)
    }

    func navigateBack() {
        path.removeLast()
    }

    func reset() {
        path.removeLast(path.count)
    }
}
