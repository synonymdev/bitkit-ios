import BitkitCore
import LDKNode
import SwiftUI

enum Route: Hashable {
    case savingsWallet
    case spendingWallet
    case hardwareWallet(deviceId: String)
    case activityList
    case activityDetail(Activity)
    case activityExplorer(Activity)
    case buyBitcoin
    case contacts
    case contactsIntro
    case contactDetail(publicKey: String)
    case contactActivity(publicKey: String)
    case assignActivityContact(activityId: String)
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

    /// Widgets
    case widgetsIntro

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
    case paymentPreference

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
    case legacyRnRecovery
    case orders
    case logs
    case trezor
}

extension Route {
    var isContactImportRoute: Bool {
        switch self {
        case .contactImportOverview, .contactImportSelect:
            true
        default:
            false
        }
    }
}

func shouldDiscardPendingImport(currentRoute: Route?, destination: Route?) -> Bool {
    guard currentRoute?.isContactImportRoute == true else {
        return false
    }

    return destination?.isContactImportRoute != true
}

func fallbackRouteForMissingPendingImport(hasPendingImport: Bool) -> Route? {
    hasPendingImport ? nil : .payContacts
}

func resolvePubkyRoute(input: String, ownPublicKey: String?, contacts: [PubkyContact]) -> Route? {
    guard PaykitFeatureFlags.isUIEnabled else {
        return nil
    }

    guard let normalizedKey = PubkyPublicKeyFormat.normalized(input) else {
        return nil
    }

    if PubkyPublicKeyFormat.matches(normalizedKey, ownPublicKey) {
        return .profile
    }

    if contacts.contains(where: { PubkyPublicKeyFormat.matches($0.publicKey, normalizedKey) }) {
        return .contactDetail(publicKey: normalizedKey)
    }

    return .addContact(publicKey: normalizedKey)
}

func resolvePastedPubkyRoute(input: String, ownPublicKey: String?, contacts: [PubkyContact]) -> Route? {
    resolvePubkyRoute(input: input, ownPublicKey: ownPublicKey, contacts: contacts)
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
