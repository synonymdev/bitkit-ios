import BitkitCore
import LDKNode
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
    case transferIntro
    case fundingOptions
    case spendingIntro
    case spendingAmount
    case spendingConfirm(order: IBtOrder)
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
    case scanner

    // Shop
    case shopIntro
    case shopDiscover
    case shopMain(page: String)
    case shopMap

    // Widgets
    case widgetsIntro
    case widgetsList
    case widgetDetail(WidgetType)
    case widgetEdit(WidgetType)

    // Main Settings
    case settings
    case generalSettings
    case securitySettings
    case backupSettings
    case advancedSettings
    case support
    case about
    case devSettings

    // General settings
    case languageSettings
    case currencySettings
    case unitSettings
    case transactionSpeedSettings
    case customSpeedSettings
    case tagSettings
    case widgetsSettings
    case quickpay
    case quickpayIntro
    case notifications
    case notificationsIntro

    // Security settings
    case disablePin
    case changePin

    // Backup settings
    case resetAndRestore

    // Advanced settings
    case coinSelection
    case connections
    case connectionDetail(channelId: String)
    case closeConnection(channel: ChannelDetails)
    case node
    case electrumSettings
    case rgsSettings
    case addressViewer

    // Support settings
    case reportIssue
    case appStatus

    // Dev settings
    case blocktankRegtest
    case orders
    case logs
}

@MainActor
class NavigationViewModel: ObservableObject {
    @Published var path: [Route] = []
    @Published var activeDrawerMenuItem: DrawerMenuItem = .wallet

    var currentRoute: Route? {
        path.last
    }

    var canGoBack: Bool {
        return !path.isEmpty
    }

    func navigate(_ route: Route) {
        path.append(route)
    }

    func navigateBack() {
        path.removeLast()
    }

    func reset() {
        path.removeLast(path.count)
        activeDrawerMenuItem = .wallet
    }
}
