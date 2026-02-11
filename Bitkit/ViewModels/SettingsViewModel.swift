import Combine
import Foundation
import LDKNode
import SwiftUI
import UserNotifications

/// Typealias for LDKNode.AddressType to avoid naming conflicts with local AddressType enums
/// used elsewhere in the app for UI purposes (e.g., receiving/change in AddressViewer).
typealias AddressScriptType = LDKNode.AddressType

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

    /// Flag to prevent concurrent address type changes
    private var isChangingAddressType = false
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

    // Address Type Settings
    @AppStorage("selectedAddressType") private var _selectedAddressType: String = "nativeSegwit"

    // Monitored Address Types - stored as comma-separated string for @AppStorage compatibility
    // Default to only Native Segwit, matching React Native behavior
    @AppStorage("addressTypesToMonitor") private var _addressTypesToMonitor: String = "nativeSegwit"

    /// All available address types
    static let allAddressTypes: [AddressScriptType] = [.legacy, .nestedSegwit, .nativeSegwit, .taproot]

    /// Convert address type to string for storage
    static func addressTypeToString(_ addressType: AddressScriptType) -> String {
        switch addressType {
        case .legacy: return "legacy"
        case .nestedSegwit: return "nestedSegwit"
        case .nativeSegwit: return "nativeSegwit"
        case .taproot: return "taproot"
        }
    }

    /// Convert string to address type
    static func stringToAddressType(_ string: String) -> AddressScriptType? {
        switch string {
        case "legacy": return .legacy
        case "nestedSegwit": return .nestedSegwit
        case "nativeSegwit": return .nativeSegwit
        case "taproot": return .taproot
        default: return nil
        }
    }

    /// Address types currently being monitored
    var addressTypesToMonitor: [AddressScriptType] {
        get {
            let strings = _addressTypesToMonitor.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return strings.compactMap { Self.stringToAddressType($0) }
        }
        set {
            _addressTypesToMonitor = newValue.map { Self.addressTypeToString($0) }.joined(separator: ",")
        }
    }

    /// Check if an address type is being monitored
    func isMonitoring(_ addressType: AddressScriptType) -> Bool {
        addressTypesToMonitor.contains(addressType)
    }

    /// Check if an address type has balance
    /// - Parameter addressType: The address type to check
    /// - Returns: The balance in sats, or 0 if unable to check
    func getBalanceForAddressType(_ addressType: AddressScriptType) async -> UInt64 {
        do {
            let balance = try await lightningService.getBalanceForAddressType(addressType)
            return balance.totalSats
        } catch {
            Logger.error("Failed to get balance for address type \(addressType): \(error)")
            return 0
        }
    }

    /// Enable or disable monitoring for an address type
    /// - Parameters:
    ///   - addressType: The address type to toggle
    ///   - enabled: Whether to enable or disable monitoring
    ///   - wallet: Optional wallet view model to update UI state during restart
    /// - Returns: True if the operation succeeded, false if it was prevented (e.g., type has balance)
    func setMonitoring(_ addressType: AddressScriptType, enabled: Bool, wallet: WalletViewModel? = nil) async -> Bool {
        guard !isChangingAddressType else { return false }

        var current = addressTypesToMonitor

        if enabled {
            if !current.contains(addressType) {
                current.append(addressType)
                addressTypesToMonitor = current
            }
        } else {
            // Don't allow disabling if it's the currently selected type
            if addressType == selectedAddressType { return false }

            // Check if address type has balance - don't allow disabling if it has funds
            let balance = await getBalanceForAddressType(addressType)
            if balance > 0 { return false }

            // If primary is Legacy, ensure at least one SegWit-compatible wallet remains enabled
            // (Legacy UTXOs cannot be used for Lightning channel funding)
            if selectedAddressType == .legacy {
                let segwitTypes: [AddressScriptType] = [.nestedSegwit, .nativeSegwit, .taproot]
                let remainingSegwit = current.filter { $0 != addressType && segwitTypes.contains($0) }
                if remainingSegwit.isEmpty {
                    return false
                }
            }

            current.removeAll { $0 == addressType }
            addressTypesToMonitor = current
        }

        UserDefaults.standard.synchronize()

        do {
            try await lightningService.restart()
            try await lightningService.sync()
        } catch {
            Logger.error("Failed to restart node after monitored types change: \(error)")
        }

        wallet?.syncState()
        return true
    }

    /// Add an address type to monitored types if not already present
    func ensureMonitoring(_ addressType: AddressScriptType) {
        if !addressTypesToMonitor.contains(addressType) {
            var current = addressTypesToMonitor
            current.append(addressType)
            addressTypesToMonitor = current
        }
    }

    /// Set all address types as monitored (used during wallet restore)
    func monitorAllAddressTypes() {
        addressTypesToMonitor = Self.allAddressTypes
    }

    /// Check if disabling an address type would leave no SegWit wallets when Legacy is primary
    /// - Parameter addressType: The address type to check
    /// - Returns: True if this is the last SegWit wallet and Legacy is primary
    func isLastRequiredSegwitWallet(_ addressType: AddressScriptType) -> Bool {
        // Only applies when Legacy is the primary wallet
        guard selectedAddressType == .legacy else { return false }

        // Only applies to SegWit-compatible types
        let segwitTypes: [AddressScriptType] = [.nestedSegwit, .nativeSegwit, .taproot]
        guard segwitTypes.contains(addressType) else { return false }

        // Check if disabling this would leave no SegWit wallets
        let remainingSegwit = addressTypesToMonitor.filter { $0 != addressType && segwitTypes.contains($0) }
        return remainingSegwit.isEmpty
    }

    var selectedAddressType: AddressScriptType {
        get {
            // Parse the stored string value
            switch _selectedAddressType {
            case "legacy":
                return .legacy
            case "nestedSegwit":
                return .nestedSegwit
            case "nativeSegwit":
                return .nativeSegwit
            case "taproot":
                return .taproot
            default:
                return .nativeSegwit // Default fallback
            }
        }
        set {
            // Convert AddressScriptType to string for storage
            switch newValue {
            case .legacy:
                _selectedAddressType = "legacy"
            case .nestedSegwit:
                _selectedAddressType = "nestedSegwit"
            case .nativeSegwit:
                _selectedAddressType = "nativeSegwit"
            case .taproot:
                _selectedAddressType = "taproot"
            }
        }
    }

    func updateAddressType(_ addressType: AddressScriptType, wallet: WalletViewModel? = nil) async {
        guard !isChangingAddressType else { return }
        guard addressType != selectedAddressType else { return }

        isChangingAddressType = true
        defer { isChangingAddressType = false }

        selectedAddressType = addressType
        ensureMonitoring(addressType)

        // Clear cached address
        UserDefaults.standard.set("", forKey: "onchainAddress")
        UserDefaults.standard.set("", forKey: "bip21")
        UserDefaults.standard.synchronize()

        if let wallet {
            wallet.onchainAddress = ""
            wallet.bip21 = ""
        }

        do {
            try await lightningService.restart()
            try await lightningService.sync()
            await generateAndUpdateAddress(addressType: addressType, wallet: wallet)
        } catch {
            Logger.error("Failed to restart node after address type change: \(error)")
            await generateAndUpdateAddress(addressType: addressType, wallet: wallet)
        }

        wallet?.syncState()
    }

    /// Generate a new address for the specified type and update wallet properties
    private func generateAndUpdateAddress(addressType: AddressScriptType, wallet: WalletViewModel?) async {
        do {
            let newAddress = try await lightningService.newAddressForType(addressType)

            UserDefaults.standard.set(newAddress, forKey: "onchainAddress")
            UserDefaults.standard.synchronize()

            if let wallet {
                wallet.onchainAddress = newAddress
                wallet.bip21 = "bitcoin:\(newAddress)"
            }
        } catch {
            Logger.error("Failed to generate new address: \(error)")
            UserDefaults.standard.set("", forKey: "onchainAddress")
            UserDefaults.standard.synchronize()
            if let wallet {
                wallet.onchainAddress = ""
            }
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
