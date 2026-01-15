import Combine
import Foundation
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
class SettingsViewModel: NSObject, ObservableObject {
    static let shared = SettingsViewModel()

    private let defaults = UserDefaults.standard
    private var observedKeys: Set<String> = []

    // Reactive publishers for settings changes (used by BackupService)
    private let settingsSubject = PassthroughSubject<[String: Any], Never>()
    private let widgetsSubject = PassthroughSubject<Data?, Never>()
    private let appStateSubject = PassthroughSubject<Void, Never>()

    nonisolated var settingsPublisher: AnyPublisher<[String: Any], Never> {
        settingsSubject
            .removeDuplicates { old, new in
                NSDictionary(dictionary: old).isEqual(to: new)
            }
            .eraseToAnyPublisher()
    }

    nonisolated var widgetsPublisher: AnyPublisher<Data?, Never> {
        widgetsSubject
            .removeDuplicates { old, new in
                if let old, let new {
                    return old.elementsEqual(new)
                }
                return old == nil && new == nil
            }
            .eraseToAnyPublisher()
    }

    nonisolated var appStatePublisher: AnyPublisher<Void, Never> {
        appStateSubject.eraseToAnyPublisher()
    }

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
    @AppStorage("ignoresSwitchUnitToast") var ignoresSwitchUnitToast: Bool = false
    @AppStorage("ignoresHideBalanceToast") var ignoresHideBalanceToast: Bool = false

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

    // MARK: - Settings Keys Configuration (for backup/restore)

    // Uses SettingsBackupConfig for configuration data (non-actor type)

    // MARK: - Initialization

    override private init() {
        lightningService = .shared
        electrumConfigService = ElectrumConfigService()
        rgsConfigService = RgsConfigService()
        electrumCurrentServer = electrumConfigService.getCurrentServer()

        super.init()

        // Initialize publishers with current state
        settingsSubject.send(getSettingsDictionary())
        widgetsSubject.send(defaults.data(forKey: "savedWidgets"))

        // Set up KVO observation
        for key in SettingsBackupConfig.settingsKeys {
            defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
            observedKeys.insert(key)
        }
        defaults.addObserver(self, forKeyPath: "savedWidgets", options: [.new], context: nil)
        observedKeys.insert("savedWidgets")

        for key in SettingsBackupConfig.appStateKeys {
            defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
            observedKeys.insert(key)
        }

        if hideBalanceOnOpen {
            hideBalance = true
        }

        updatePinEnabledState()
    }

    deinit {
        for key in observedKeys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if SettingsBackupConfig.settingsKeys.contains(keyPath ?? "") {
            settingsSubject.send(getSettingsDictionary())
        } else if keyPath == "savedWidgets" {
            widgetsSubject.send(defaults.data(forKey: "savedWidgets"))
        } else if SettingsBackupConfig.appStateKeys.contains(keyPath ?? "") {
            appStateSubject.send()
        }
    }

    nonisolated func notifyAppStateChanged() {
        appStateSubject.send()
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
    @AppStorage("coinSelectionAlgorithm") private var _coinSelectionAlgorithm: String = CoinSelectionAlgorithm.branchAndBound.stringValue

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

    // MARK: - Backup/Restore

    /// Gets all settings from UserDefaults as a dictionary for backup
    func getSettingsDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]

        for (key, type) in SettingsBackupConfig.settingsKeyTypes {
            guard defaults.object(forKey: key) != nil else { continue }

            let value: Any?
            switch type {
            case let .string(optional):
                if let stringValue = defaults.string(forKey: key) {
                    value = stringValue
                } else if !optional {
                    value = ""
                } else {
                    value = nil
                }
            case .bool:
                value = defaults.bool(forKey: key)
            case let .double(optional, minValue):
                let doubleValue = defaults.double(forKey: key)
                if doubleValue > minValue {
                    value = doubleValue
                } else if !optional {
                    value = doubleValue
                } else {
                    value = nil
                }
            case let .int(optional, minValue):
                let intValue = defaults.integer(forKey: key)
                if intValue > minValue {
                    value = intValue
                } else if !optional {
                    value = intValue
                } else {
                    value = nil
                }
            case let .stringArray(optional):
                if let arrayValue = defaults.stringArray(forKey: key), !arrayValue.isEmpty {
                    value = arrayValue
                } else if !optional {
                    value = []
                } else {
                    value = nil
                }
            }

            if let value {
                if key == "coinSelectionMethod", let methodString = value as? String {
                    let coinSelectAuto = methodString == "autopilot"
                    dict["coinSelectAuto"] = coinSelectAuto
                } else if key == "coinSelectionAlgorithm", let algorithmString = value as? String {
                    let androidPreference = SettingsBackupConfig.convertAlgorithm(algorithmString, toAndroid: true)
                    dict["coinSelectPreference"] = androidPreference
                } else {
                    let androidKey = SettingsBackupConfig.iosToAndroidFieldMapping[key] ?? key
                    if key == "quickpayAmount", let doubleValue = value as? Double {
                        dict[androidKey] = Int(doubleValue)
                    } else {
                        dict[androidKey] = value
                    }
                }
            }
        }

        let electrumServerUrl = electrumConfigService.getCurrentServer().fullUrl
        if !electrumServerUrl.isEmpty { dict["electrumServer"] = electrumServerUrl }

        let rgsServerUrl = rgsConfigService.getCurrentServerUrl()
        if !rgsServerUrl.isEmpty { dict["rgsServerUrl"] = rgsServerUrl }

        dict["isDevModeEnabled"] = Env.isDebug && Env.network != .bitcoin

        return dict
    }

    /// Parses Electrum server URL from backup format (handles various formats)
    private func parseElectrumServerUrlForRestore(_ urlString: String) -> ElectrumServer? {
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") && !urlString.hasPrefix("tcp://") && !urlString.hasPrefix("ssl://") {
            let parts = urlString.split(separator: ":")
            guard parts.count >= 2 else { return nil }

            let host = String(parts[0])
            let port = String(parts[1])
            let shortProtocol = parts.count > 2 ? String(parts[2]) : nil

            let protocolType: ElectrumProtocol = if let shortProtocol {
                shortProtocol == "s" ? .ssl : .tcp
            } else {
                electrumConfigService.getProtocolForPort(port)
            }

            return ElectrumServer(host: host, portString: port, protocolType: protocolType)
        }

        if urlString.hasPrefix("tcp://") || urlString.hasPrefix("ssl://") {
            let withoutProtocol = String(urlString.dropFirst(6)) // Remove "ssl://" or "tcp://"
            let parts = withoutProtocol.split(separator: ":")
            guard parts.count >= 2 else { return nil }

            let host = String(parts[0])
            let port = String(parts[1])
            let protocolType: ElectrumProtocol = urlString.hasPrefix("ssl://") ? .ssl : .tcp

            return ElectrumServer(host: host, portString: port, protocolType: protocolType)
        }

        guard let url = URL(string: urlString) else { return nil }

        let host = url.host ?? ""
        let port = (url.port ?? 0) > 0 ? String(url.port ?? 0) : (url.scheme == "https" ? "443" : "80")
        let protocolType: ElectrumProtocol = url.scheme == "https" ? .ssl : .tcp

        return ElectrumServer(host: host, portString: port, protocolType: protocolType)
    }

    /// Restores settings dictionary to UserDefaults
    func restoreSettingsDictionary(_ dict: [String: Any]) {
        if let coinSelectAuto = dict["coinSelectAuto"] as? Bool {
            let methodString = coinSelectAuto ? "autopilot" : "manual"
            defaults.set(methodString, forKey: "coinSelectionMethod")
        }

        if let coinSelectPreference = dict["coinSelectPreference"] as? String {
            let iosAlgorithm = SettingsBackupConfig.convertAlgorithm(coinSelectPreference, toAndroid: false)
            defaults.set(iosAlgorithm, forKey: "coinSelectionAlgorithm")
        }

        for (iosKey, type) in SettingsBackupConfig.settingsKeyTypes {
            if iosKey == "coinSelectionMethod" || iosKey == "coinSelectionAlgorithm" {
                continue
            }

            let androidKey = SettingsBackupConfig.iosToAndroidFieldMapping[iosKey] ?? iosKey
            guard let value = dict[androidKey] ?? dict[iosKey] else {
                defaults.removeObject(forKey: iosKey)
                continue
            }

            switch type {
            case .string:
                if let stringValue = value as? String {
                    defaults.set(stringValue, forKey: iosKey)
                }
            case .bool:
                if let boolValue = value as? Bool {
                    defaults.set(boolValue, forKey: iosKey)
                }
            case .double:
                if let doubleValue = value as? Double {
                    defaults.set(doubleValue, forKey: iosKey)
                } else if let intValue = value as? Int {
                    defaults.set(Double(intValue), forKey: iosKey)
                } else if let longValue = value as? Int64 {
                    defaults.set(Double(longValue), forKey: iosKey)
                }
            case .int:
                if let intValue = value as? Int {
                    defaults.set(intValue, forKey: iosKey)
                } else if let doubleValue = value as? Double {
                    defaults.set(Int(doubleValue), forKey: iosKey)
                }
            case .stringArray:
                if let arrayValue = value as? [String] {
                    defaults.set(arrayValue, forKey: iosKey)
                }
            }
        }

        if let electrumServerUrl = dict["electrumServer"] as? String, !electrumServerUrl.isEmpty {
            if let server = parseElectrumServerUrlForRestore(electrumServerUrl) {
                electrumConfigService.saveServerConfig(server)
            }
        }

        if let rgsServerUrl = dict["rgsServerUrl"] as? String, !rgsServerUrl.isEmpty {
            rgsConfigService.saveServerUrl(rgsServerUrl)
        }
    }

    /// Gets the current app cache data for backup
    func getAppCacheData() -> AppCacheData {
        AppCacheData(
            hasSeenContactsIntro: defaults.bool(forKey: "hasSeenContactsIntro"),
            hasSeenProfileIntro: defaults.bool(forKey: "hasSeenProfileIntro"),
            hasSeenNotificationsIntro: defaults.bool(forKey: "hasSeenNotificationsIntro"),
            hasSeenQuickpayIntro: defaults.bool(forKey: "hasSeenQuickpayIntro"),
            hasSeenShopIntro: defaults.bool(forKey: "hasSeenShopIntro"),
            hasSeenTransferIntro: defaults.bool(forKey: "hasSeenTransferIntro"),
            hasSeenTransferToSpendingIntro: defaults.bool(forKey: "hasSeenTransferToSpendingIntro"),
            hasSeenTransferToSavingsIntro: defaults.bool(forKey: "hasSeenTransferToSavingsIntro"),
            hasSeenWidgetsIntro: defaults.bool(forKey: "hasSeenWidgetsIntro"),
            showHomeViewEmptyState: defaults.bool(forKey: "showHomeViewEmptyState"),
            appUpdateIgnoreTimestamp: defaults.double(forKey: "appUpdateIgnoreTimestamp"),
            backupIgnoreTimestamp: defaults.double(forKey: "backupIgnoreTimestamp"),
            highBalanceIgnoreCount: defaults.integer(forKey: "highBalanceIgnoreCount"),
            highBalanceIgnoreTimestamp: defaults.double(forKey: "highBalanceIgnoreTimestamp"),
            dismissedSuggestions: defaults.stringArray(forKey: "dismissedSuggestions") ?? [],
            lastUsedTags: defaults.stringArray(forKey: "lastUsedTags") ?? []
        )
    }

    /// Restores app cache data from backup
    func restoreAppCacheData(_ cache: AppCacheData) {
        defaults.set(cache.hasSeenContactsIntro, forKey: "hasSeenContactsIntro")
        defaults.set(cache.hasSeenProfileIntro, forKey: "hasSeenProfileIntro")
        defaults.set(cache.hasSeenNotificationsIntro, forKey: "hasSeenNotificationsIntro")
        defaults.set(cache.hasSeenQuickpayIntro, forKey: "hasSeenQuickpayIntro")
        defaults.set(cache.hasSeenShopIntro, forKey: "hasSeenShopIntro")
        defaults.set(cache.hasSeenTransferIntro, forKey: "hasSeenTransferIntro")
        defaults.set(cache.hasSeenTransferToSpendingIntro, forKey: "hasSeenTransferToSpendingIntro")
        defaults.set(cache.hasSeenTransferToSavingsIntro, forKey: "hasSeenTransferToSavingsIntro")
        defaults.set(cache.hasSeenWidgetsIntro, forKey: "hasSeenWidgetsIntro")
        defaults.set(cache.showHomeViewEmptyState, forKey: "showHomeViewEmptyState")
        defaults.set(cache.appUpdateIgnoreTimestamp, forKey: "appUpdateIgnoreTimestamp")
        defaults.set(cache.backupIgnoreTimestamp, forKey: "backupIgnoreTimestamp")
        defaults.set(cache.highBalanceIgnoreCount, forKey: "highBalanceIgnoreCount")
        defaults.set(cache.highBalanceIgnoreTimestamp, forKey: "highBalanceIgnoreTimestamp")
        defaults.set(cache.dismissedSuggestions, forKey: "dismissedSuggestions")
        defaults.set(cache.lastUsedTags, forKey: "lastUsedTags")
    }
}
