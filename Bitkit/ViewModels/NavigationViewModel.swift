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
    case notifications
    case notificationsIntro
    case profile
    case profileIntro
    case quickpay
    case quickpayIntro
    case transferIntro
    case fundingOptions
    case spendingIntro
    case spendingAmount
    case spendingConfirm
    case spendingAdvanced(order: IBtOrder)
    case transferLearnMore(order: IBtOrder)
    case settingUp
    case fundingAdvanced
    case fundManual(nodeUri: String?)
    case fundManualSuccess
    case lnurlChannel(channelData: LnurlChannelData)
    case savingsIntro
    case savingsAvailability
    case savingsConfirm
    case savingsAdvanced
    case savingsProgress
    case settings
    case generalSettings
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
