import Combine
import Foundation
import LDKNode
import SwiftUI
import UserNotifications

// Avoids conflict with AddressViewer.AddressType
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

    /// Call after removePersistentDomain; singleton retains stale @AppStorage values.
    func resetToDefaults() {
        _swipeBalanceToHide = true
        defaultTransactionSpeed = .normal
        hideBalance = false
        hideBalanceOnOpen = false
        readClipboard = false
        warnWhenSendingOver100 = false
        enableQuickpay = false
        quickpayAmount = 5
        enableNotifications = false
        enableNotificationsAmount = false
        ignoresSwitchUnitToast = false
        ignoresHideBalanceToast = false
        pinFailedAttempts = 0
        requirePinForPayments = false
        useBiometrics = false
        showWidgets = true
        showWidgetTitles = false
        _coinSelectionMethod = CoinSelectionMethod.autopilot.rawValue
        _coinSelectionAlgorithm = CoinSelectionAlgorithm.branchAndBound.stringValue
        _selectedAddressType = "nativeSegwit"
        _addressTypesToMonitor = "nativeSegwit"
        pinEnabled = false
        isChangingAddressType = false
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

    @AppStorage("addressTypesToMonitor") private var _addressTypesToMonitor: String = "nativeSegwit"

    static let allAddressTypes: [AddressScriptType] = [.legacy, .nestedSegwit, .nativeSegwit, .taproot]

    static func addressTypeToString(_ addressType: AddressScriptType) -> String {
        switch addressType {
        case .legacy: return "legacy"
        case .nestedSegwit: return "nestedSegwit"
        case .nativeSegwit: return "nativeSegwit"
        case .taproot: return "taproot"
        }
    }

    static func stringToAddressType(_ string: String) -> AddressScriptType? {
        switch string {
        case "legacy": return .legacy
        case "nestedSegwit": return .nestedSegwit
        case "nativeSegwit": return .nativeSegwit
        case "taproot": return .taproot
        default: return nil
        }
    }

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

    func getBalanceForAddressType(_ addressType: AddressScriptType) async throws -> UInt64 {
        let balance = try await lightningService.getBalanceForAddressType(addressType)
        return balance.totalSats
    }

    func setMonitoring(_ addressType: AddressScriptType, enabled: Bool, wallet: WalletViewModel? = nil) async -> Bool {
        guard !isChangingAddressType else { return false }

        isChangingAddressType = true
        defer { isChangingAddressType = false }

        let previousAddressTypesToMonitor = addressTypesToMonitor
        var current = addressTypesToMonitor

        if enabled {
            if !current.contains(addressType) {
                current.append(addressType)
                addressTypesToMonitor = current
            }
        } else {
            if addressType == selectedAddressType { return false }

            do {
                let balance = try await getBalanceForAddressType(addressType)
                if balance > 0 { return false }
            } catch {
                // Fail safely: block disable if balance check fails
                Logger.error("Failed to check balance for \(addressType), preventing disable: \(error)")
                return false
            }

            // At least one native witness type required for Lightning
            let nativeWitnessTypes: [AddressScriptType] = [.nativeSegwit, .taproot]
            let remainingNativeWitness = current.filter { $0 != addressType && nativeWitnessTypes.contains($0) }
            if remainingNativeWitness.isEmpty {
                return false
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
            addressTypesToMonitor = previousAddressTypesToMonitor
            UserDefaults.standard.synchronize()
            return false
        }

        wallet?.syncState()
        return true
    }

    func ensureMonitoring(_ addressType: AddressScriptType) {
        if !addressTypesToMonitor.contains(addressType) {
            var current = addressTypesToMonitor
            current.append(addressType)
            addressTypesToMonitor = current
        }
    }

    func monitorAllAddressTypes() {
        addressTypesToMonitor = Self.allAddressTypes
    }

    private static let pendingRestoreAddressTypePruneKey = "pendingRestoreAddressTypePrune"

    /// Tracks whether to prune empty address types after restore (set when user taps Get Started; cleared when prune runs).
    var pendingRestoreAddressTypePrune: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pendingRestoreAddressTypePruneKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingRestoreAddressTypePruneKey) }
    }

    /// After restore, disables monitoring for address types with zero balance.
    /// Keeps nativeSegwit as primary and monitored; only types with funds stay monitored.
    func pruneEmptyAddressTypesAfterRestore() async {
        guard !isChangingAddressType else { return }

        let nativeWitnessTypes: [AddressScriptType] = [.nativeSegwit, .taproot]
        var newMonitored = addressTypesToMonitor
        var changed = false

        for type in addressTypesToMonitor {
            // Always keep nativeSegwit (primary, required for Lightning)
            if type == .nativeSegwit { continue }

            do {
                let balance = try await getBalanceForAddressType(type)
                if balance == 0 {
                    newMonitored.removeAll { $0 == type }
                    changed = true
                    Logger.debug("Pruned empty address type from monitoring: \(type)", context: "SettingsViewModel")
                }
            } catch {
                Logger.warn("Could not check balance for \(type), keeping monitored: \(error)")
                // Don't disable on error - fail safe
            }
        }

        // Ensure at least one native witness type
        if !newMonitored.contains(where: { nativeWitnessTypes.contains($0) }) {
            if !newMonitored.contains(.nativeSegwit) {
                newMonitored.append(.nativeSegwit)
                changed = true
            }
        }

        guard changed else { return }

        addressTypesToMonitor = newMonitored
        UserDefaults.standard.synchronize()

        do {
            try await lightningService.restart()
            try await lightningService.sync()
            Logger.info(
                "Pruned empty address types after restore: \(newMonitored.map { Self.addressTypeToString($0) }.joined(separator: ","))",
                context: "SettingsViewModel"
            )
        } catch {
            Logger.error("Failed to restart after prune: \(error)")
        }
    }

    /// True if disabling this would leave no native witness wallet (required for Lightning).
    func isLastRequiredNativeWitnessWallet(_ addressType: AddressScriptType) -> Bool {
        let nativeWitnessTypes: [AddressScriptType] = [.nativeSegwit, .taproot]
        guard nativeWitnessTypes.contains(addressType) else { return false }

        let remainingNativeWitness = addressTypesToMonitor.filter { $0 != addressType && nativeWitnessTypes.contains($0) }
        return remainingNativeWitness.isEmpty
    }

    var selectedAddressType: AddressScriptType {
        get {
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
                return .nativeSegwit
            }
        }
        set {
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

    func updateAddressType(_ addressType: AddressScriptType, wallet: WalletViewModel? = nil) async -> Bool {
        guard !isChangingAddressType else { return false }
        guard addressType != selectedAddressType else { return true }

        isChangingAddressType = true
        defer { isChangingAddressType = false }

        let previousSelectedAddressType = selectedAddressType
        let previousAddressTypesToMonitor = addressTypesToMonitor
        let previousOnchainAddress = UserDefaults.standard.string(forKey: "onchainAddress") ?? ""
        let previousBip21 = UserDefaults.standard.string(forKey: "bip21") ?? ""

        selectedAddressType = addressType
        ensureMonitoring(addressType)

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
            selectedAddressType = previousSelectedAddressType
            addressTypesToMonitor = previousAddressTypesToMonitor
            UserDefaults.standard.set(previousOnchainAddress, forKey: "onchainAddress")
            UserDefaults.standard.set(previousBip21, forKey: "bip21")
            UserDefaults.standard.synchronize()
            if let wallet {
                wallet.onchainAddress = previousOnchainAddress
                wallet.bip21 = previousBip21
            }
            wallet?.syncState()
            return false
        }

        wallet?.syncState()
        return true
    }

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
