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
    case contactDetail(publicKey: String)
    case contactImportOverview
    case contactImportSelect
    case addContact(publicKey: String)
    case editContact(publicKey: String)
    case profile
    case profileIntro
    case pubkyChoice
    case createProfile
    case editProfile
    case payContacts
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
    case fundManualAmount(lnPeer: LnPeer)
    case fundManualConfirm(lnPeer: LnPeer, amountSats: UInt64)
    case fundManualSuccess
    case lnurlChannel(channelData: LnurlChannelData)
    case savingsIntro
    case savingsAvailability
    case savingsConfirm
    case savingsAdvanced
    case savingsProgress
    case scanner
    case support

    // Shop
    case shopIntro
    case shopDiscover
    case shopMain(page: String)

    // Widgets
    case widgetsIntro
    case widgetsList
    case widgetDetail(WidgetType)
    case widgetEdit(WidgetType)

    // Support
    case reportIssue
    case appStatus

    // Settings
    // General/Interface
    case settings
    case languageSettings
    case currencySettings
    case unitSettings
    case tagSettings
    case widgetsSettings

    // General/Payments
    case transactionSpeedSettings
    case customSpeedSettings
    case quickpay
    case quickpayIntro
    case notifications
    case notificationsIntro

    // Security
    case dataBackups
    case reset
    case changePin

    // Advanced/Payments
    case coinSelection
    case addressTypePreference
    case connections
    case connectionDetail(channelId: String)
    case closeConnection(channel: ChannelDetails)
    case node
    case electrumSettings
    case rgsSettings
    case addressViewer
    case devSettings

    // Dev settings
    case blocktankRegtest
    case ldkDebug
    case vssDebug
    case probingTool
    case orders
    case logs
}

@MainActor
class NavigationViewModel: ObservableObject {
    @Published var path: [Route] = []

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
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func reset() {
        path.removeAll()
    }
}
