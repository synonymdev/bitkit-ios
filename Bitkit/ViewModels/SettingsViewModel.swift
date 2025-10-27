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
    @AppStorage("enableNotifications") var enableNotifications: Bool = false
    @AppStorage("enableNotificationsAmount") var enableNotificationsAmount: Bool = false // TODO: remove this

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

    // RGS Server Settings
    @Published var rgsServerUrl: String = ""
    @Published var rgsIsLoading: Bool = false

    // Services
    let lightningService: LightningService
    let electrumConfigService: ElectrumConfigService
    let rgsConfigService: RgsConfigService

    // MARK: - Initialization

    init(
        lightningService: LightningService = .shared,
        electrumConfigService: ElectrumConfigService = ElectrumConfigService(),
        rgsConfigService: RgsConfigService = RgsConfigService()
    ) {
        self.lightningService = lightningService
        self.electrumConfigService = electrumConfigService
        self.rgsConfigService = rgsConfigService

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

    var rgsHasEdited: Bool {
        let formUrl = rgsServerUrl.trimmingCharacters(in: .whitespaces)
        let currentUrl = rgsConfigService.getCurrentServerUrl()
        return formUrl != currentUrl
    }

    var rgsCanConnect: Bool {
        let formUrl = rgsServerUrl.trimmingCharacters(in: .whitespaces)
        return rgsHasEdited && !formUrl.isEmpty && isValidRgsUrl(formUrl)
    }

    var rgsCanReset: Bool {
        let formUrl = rgsServerUrl.trimmingCharacters(in: .whitespaces)
        let defaultUrl = rgsConfigService.getDefaultServerUrl()
        return formUrl != defaultUrl
    }

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

    // MARK: - RGS URL Validation

    func isValidRgsUrl(_ url: String) -> Bool {
        // Allow empty URL (disables RGS)
        if url.isEmpty {
            return true
        }

        // Check if URL is valid
        guard let urlObj = URL(string: url) else {
            return false
        }

        // Must be HTTPS
        guard urlObj.scheme == "https" else {
            return false
        }

        // Must have a host
        guard urlObj.host != nil else {
            return false
        }

        // Allow localhost in development mode
        if Env.isDebug && url.contains("localhost") {
            return true
        }

        // Basic URL pattern validation
        let pattern = #"^(https?:\/\/)?((([a-z\d]([a-z\d-]*[a-z\d])*)\.)+[a-z]{2,}|((\d{1,3}\.){3}\d{1,3}))(\:\d+)?(\/[-a-z\d%_.~+]*)*"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: url.utf16.count)
        return regex?.firstMatch(in: url, options: [], range: range) != nil
    }
}
