import BitkitCore
import SwiftUI

enum Route: Hashable {
    case savingsWallet
    case spendingWallet
    case activityList
    case activityDetail(Activity)
    case activityExplorer(Activity)
    case buyBitcoin
    case contacts
    case contactsIntro
    case profile
    case profileIntro
    case quickpay
    case quickpayIntro
    case transferIntro
    case fundingOptions
    case fundingAmount
    case savingsIntro
    case savingsAvailability
    case settings
    case shopIntro
    case shopDiscover
    case shopMain(page: String)
    case support
    case widgetsIntro
    case widgetsList
    case widgetDetail(WidgetType)
    case widgetEdit(WidgetType)
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

    func navigate(_ route: Route) {
        path.append(route)
    }

    func navigateBack() {
        path.removeLast()
    }

    func reset() {
        path.removeLast(path.count)
    }
}
