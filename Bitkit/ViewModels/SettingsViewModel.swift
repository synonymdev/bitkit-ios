import LDKNode
import SwiftUI
import UserNotifications

enum CoinSelectionMethod: String, CaseIterable {
    case manual
    case autopilot
}

extension CoinSelectionAlgorithm {
    var stringValue: String {
        switch self {
        case .branchAndBound:
            return "branchAndBound"
        case .largestFirst:
            return "largestFirst"
        case .oldestFirst:
            return "oldestFirst"
        case .singleRandomDraw:
            return "singleRandomDraw"
        }
    }

    static func from(stringValue: String) -> CoinSelectionAlgorithm {
        switch stringValue {
        case "branchAndBound":
            return .branchAndBound
        case "largestFirst":
            return .largestFirst
        case "oldestFirst":
            return .oldestFirst
        case "singleRandomDraw":
            return .singleRandomDraw
        default:
            return .largestFirst // Default fallback
        }
    }
}

@MainActor
class SettingsViewModel: ObservableObject {
    // Security & Privacy Settings
    @AppStorage("swipeBalanceToHide") private var _swipeBalanceToHide: Bool = true

    var swipeBalanceToHide: Bool {
        get { _swipeBalanceToHide }
        set {
            _swipeBalanceToHide = newValue
            if !newValue {
                // If they disable the swipe to hide, we should keep the balance visible else they'll never see it
                hideBalance = false
            }
        }
    }

    @AppStorage("defaultTransactionSpeed") var defaultTransactionSpeed: TransactionSpeed = .normal
    @AppStorage("hideBalance") var hideBalance: Bool = false
    @AppStorage("hideBalanceOnOpen") var hideBalanceOnOpen: Bool = false
    @AppStorage("readClipboard") var readClipboard: Bool = false
    @AppStorage("warnWhenSendingOver100") var warnWhenSendingOver100: Bool = false
    @AppStorage("enableQuickpay") var enableQuickpay: Bool = false
    @AppStorage("quickpayAmount") var quickpayAmount: Double = 5

    // PIN Management
    @Published internal(set) var pinEnabled: Bool = false
    @AppStorage("pinFailedAttempts") var pinFailedAttempts: Int = 0
    @AppStorage("requirePinForPayments") var requirePinForPayments: Bool = false
    @AppStorage("useBiometrics") var useBiometrics: Bool = false

    // Electrum Server Settings
    @Published var electrumHost: String = ""
    @Published var electrumPort: String = ""
    @Published var electrumSelectedProtocol: ElectrumProtocol = .tcp
    @Published var electrumCurrentServer: ElectrumServer
    @Published var electrumIsConnected: Bool = false
    @Published var electrumIsLoading: Bool = false

    // Services
    let lightningService: LightningService
    let electrumConfigService: ElectrumConfigService

    // MARK: - Initialization

    init(lightningService: LightningService = .shared, electrumConfigService: ElectrumConfigService = ElectrumConfigService()) {
        self.lightningService = lightningService
        self.electrumConfigService = electrumConfigService

        // Initialize electrumCurrentServer with current server (stored or default)
        electrumCurrentServer = electrumConfigService.getCurrentServer()

        if hideBalanceOnOpen {
            hideBalance = true
        }

        updatePinEnabledState()
    }

    // MARK: - Computed Properties

    var electrumHasEdited: Bool {
        let formHost = electrumHost.trimmingCharacters(in: .whitespaces)
        let formPort = electrumPort.trimmingCharacters(in: .whitespaces)
        let formProtocol = electrumSelectedProtocol

        let hostChanged = formHost != electrumCurrentServer.host
        let portChanged = formPort != electrumCurrentServer.portString
        let protocolChanged = formProtocol != electrumCurrentServer.protocolType

        return hostChanged || portChanged || protocolChanged
    }

    var electrumCanConnect: Bool {
        return electrumHasEdited || !electrumIsConnected
    }

    // Push Notifications
    @AppStorage("enableNotifications") var enableNotifications: Bool = false
    @AppStorage("enableNotificationsAmount") var enableNotificationsAmount: Bool = false // TODO: does nothing yet

    // Widget Settings
    @AppStorage("showWidgets") var showWidgets: Bool = true
    @AppStorage("showWidgetTitles") var showWidgetTitles: Bool = false

    // Coin Selection Settings
    @AppStorage("coinSelectionMethod") private var _coinSelectionMethod: String = CoinSelectionMethod.autopilot.rawValue
    @AppStorage("coinSelectionAlgorithm") private var _coinSelectionAlgorithm: String = CoinSelectionAlgorithm.largestFirst.stringValue

    var coinSelectionMethod: CoinSelectionMethod {
        get {
            CoinSelectionMethod(rawValue: _coinSelectionMethod) ?? .autopilot
        }
        set {
            _coinSelectionMethod = newValue.rawValue
        }
    }

    var coinSelectionAlgorithm: CoinSelectionAlgorithm {
        get {
            CoinSelectionAlgorithm.from(stringValue: _coinSelectionAlgorithm)
        }
        set {
            _coinSelectionAlgorithm = newValue.stringValue
        }
    }
}
