import Combine
import Foundation

/// Service for managing settings backup/restore operations
class SettingsStore: NSObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // Reactive publishers for settings changes
    private let settingsSubject = PassthroughSubject<[String: Any], Never>()
    private let widgetsSubject = PassthroughSubject<Data?, Never>()

    var settingsPublisher: AnyPublisher<[String: Any], Never> {
        settingsSubject
            .removeDuplicates { old, new in
                NSDictionary(dictionary: old).isEqual(to: new)
            }
            .eraseToAnyPublisher()
    }

    var widgetsPublisher: AnyPublisher<Data?, Never> {
        widgetsSubject
            .removeDuplicates { old, new in
                if let old, let new {
                    return old.elementsEqual(new)
                }
                return old == nil && new == nil
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Settings Keys Configuration

    private enum SettingKeyType {
        case string(optional: Bool)
        case bool
        case double(optional: Bool, minValue: Double = 0)
        case int(optional: Bool, minValue: Int = 0)
        case stringArray(optional: Bool)
    }

    // Server settings that require special handling (accessed via services, not directly from UserDefaults)
    private static let serverSettingsKeys: [String] = [
        "electrumServer",
        "rapidGossipSyncUrl",
    ]

    private static let settingsKeyTypes: [String: SettingKeyType] = [
        // String keys (optional)
        "primaryDisplay": .string(optional: true),
        "bitcoinDisplayUnit": .string(optional: true),
        "selectedCurrency": .string(optional: true),
        "defaultTransactionSpeed": .string(optional: true),
        "coinSelectionMethod": .string(optional: true),
        "coinSelectionAlgorithm": .string(optional: true),

        // Bool keys
        "showHomeViewEmptyState": .bool,
        "hasSeenContactsIntro": .bool,
        "hasSeenProfileIntro": .bool,
        "hasSeenNotificationsIntro": .bool,
        "hasSeenQuickpayIntro": .bool,
        "hasSeenShopIntro": .bool,
        "hasSeenTransferIntro": .bool,
        "hasSeenTransferToSpendingIntro": .bool,
        "hasSeenTransferToSavingsIntro": .bool,
        "hasSeenWidgetsIntro": .bool,
        "enableQuickpay": .bool,
        "showWidgets": .bool,
        "showWidgetTitles": .bool,
        "swipeBalanceToHide": .bool,
        "hideBalance": .bool,
        "hideBalanceOnOpen": .bool,
        "readClipboard": .bool,
        "warnWhenSendingOver100": .bool,
        "backupVerified": .bool,
        "enableNotifications": .bool,

        // Double keys
        "quickpayAmount": .double(optional: false),
        "highBalanceIgnoreTimestamp": .double(optional: true, minValue: 0),
        "backupIgnoreTimestamp": .double(optional: true, minValue: 0),
        "appUpdateIgnoreTimestamp": .double(optional: true, minValue: 0),

        // Int keys
        "highBalanceIgnoreCount": .int(optional: true, minValue: 0),

        // String array keys (optional, only if not empty)
        "lastUsedTags": .stringArray(optional: true),
        "dismissedSuggestions": .stringArray(optional: true),
    ]

    // All settings keys (for KVO observation) - includes server settings that need special handling
    private static var settingsKeys: [String] {
        Array(settingsKeyTypes.keys) + serverSettingsKeys
    }

    override private init() {
        super.init()

        settingsSubject.send(getSettingsDictionary())
        widgetsSubject.send(defaults.data(forKey: "savedWidgets"))

        for key in Self.settingsKeys {
            defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
        defaults.addObserver(self, forKeyPath: "savedWidgets", options: [.new], context: nil)
    }

    deinit {
        for key in Self.settingsKeys {
            defaults.removeObserver(self, forKeyPath: key)
        }
        defaults.removeObserver(self, forKeyPath: "savedWidgets")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if Self.settingsKeys.contains(keyPath ?? "") {
            settingsSubject.send(getSettingsDictionary())
        } else if keyPath == "savedWidgets" {
            widgetsSubject.send(defaults.data(forKey: "savedWidgets"))
        }
    }

    // MARK: - Field Name Mapping (iOS <-> Android)

    /// Maps iOS field names to Android field names for backup
    private static let iosToAndroidFieldMapping: [String: String] = [
        "readClipboard": "enableAutoReadClipboard",
        "swipeBalanceToHide": "enableSwipeToHideBalance",
        "warnWhenSendingOver100": "enableSendAmountWarning",
        "showHomeViewEmptyState": "showEmptyBalanceView",
        "bitcoinDisplayUnit": "displayUnit",
        "hasSeenTransferToSpendingIntro": "hasSeenSpendingIntro",
        "hasSeenTransferToSavingsIntro": "hasSeenSavingsIntro",
        "hasSeenQuickpayIntro": "quickPayIntroSeen",
        "hasSeenNotificationsIntro": "bgPaymentsIntroSeen",
        "enableQuickpay": "isQuickPayEnabled",
        "useBiometrics": "isBiometricEnabled",
        "requirePinForPayments": "isPinForPaymentsEnabled",
        "enableNotifications": "notificationsGranted",
        "backupIgnoreTimestamp": "backupWarningIgnoredMillis",
        "highBalanceIgnoreTimestamp": "balanceWarningIgnoredMillis",
        "highBalanceIgnoreCount": "balanceWarningTimes",
        "appUpdateIgnoreTimestamp": "notificationsIgnoredMillis",
    ]

    /// Maps Android field names to iOS field names for restore
    private static let androidToIosFieldMapping: [String: String] = [
        "enableAutoReadClipboard": "readClipboard",
        "enableSwipeToHideBalance": "swipeBalanceToHide",
        "enableSendAmountWarning": "warnWhenSendingOver100",
        "showEmptyBalanceView": "showHomeViewEmptyState",
        "displayUnit": "bitcoinDisplayUnit",
        "hasSeenSpendingIntro": "hasSeenTransferToSpendingIntro",
        "hasSeenSavingsIntro": "hasSeenTransferToSavingsIntro",
        "quickPayIntroSeen": "hasSeenQuickpayIntro",
        "bgPaymentsIntroSeen": "hasSeenNotificationsIntro",
        "isQuickPayEnabled": "enableQuickpay",
        "isBiometricEnabled": "useBiometrics",
        "isPinForPaymentsEnabled": "requirePinForPayments",
        "notificationsGranted": "enableNotifications",
        "backupWarningIgnoredMillis": "backupIgnoreTimestamp",
        "balanceWarningIgnoredMillis": "highBalanceIgnoreTimestamp",
        "balanceWarningTimes": "highBalanceIgnoreCount",
        "notificationsIgnoredMillis": "appUpdateIgnoreTimestamp",
    ]

    // MARK: - Coin Selection Conversion Helpers

    /// Converts iOS coinSelectionAlgorithm to Android coinSelectPreference
    private static func convertIosAlgorithmToAndroidPreference(_ iosAlgorithm: String) -> String {
        switch iosAlgorithm {
        case "branchAndBound":
            return "BranchAndBound"
        case "largestFirst":
            return "LargestFirst"
        case "oldestFirst":
            return "FirstInFirstOut"
        case "singleRandomDraw":
            return "SingleRandomDraw"
        default:
            return "BranchAndBound" // Default fallback
        }
    }

    /// Converts Android coinSelectPreference to iOS coinSelectionAlgorithm
    private static func convertAndroidPreferenceToIosAlgorithm(_ androidPreference: String) -> String {
        switch androidPreference {
        case "BranchAndBound":
            return "branchAndBound"
        case "LargestFirst":
            return "largestFirst"
        case "FirstInFirstOut":
            return "oldestFirst"
        case "SingleRandomDraw":
            return "singleRandomDraw"
        default:
            return "largestFirst" // Default fallback
        }
    }

    // MARK: - Backup/Restore

    /// Gets all settings from UserDefaults as a dictionary for backup
    func getSettingsDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]

        // Process all settings keys (excluding server settings which need special handling)
        for (key, type) in Self.settingsKeyTypes {
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
                // Special handling for coin selection
                if key == "coinSelectionMethod", let methodString = value as? String {
                    // Convert iOS coinSelectionMethod ("manual"/"autopilot") to Android coinSelectAuto (false/true)
                    let coinSelectAuto = methodString == "autopilot"
                    dict["coinSelectAuto"] = coinSelectAuto
                } else if key == "coinSelectionAlgorithm", let algorithmString = value as? String {
                    // Convert iOS coinSelectionAlgorithm (camelCase string) to Android coinSelectPreference (PascalCase enum)
                    let androidPreference = Self.convertIosAlgorithmToAndroidPreference(algorithmString)
                    dict["coinSelectPreference"] = androidPreference
                } else {
                    // Map iOS field name to Android field name if needed
                    let androidKey = Self.iosToAndroidFieldMapping[key] ?? key

                    // Handle type conversion for Android compatibility
                    // Android quickPayAmount is Int, iOS is Double
                    if key == "quickpayAmount", let doubleValue = value as? Double {
                        dict[androidKey] = Int(doubleValue)
                    } else {
                        dict[androidKey] = value
                    }
                }
            }
        }

        // Server settings (get from services, not directly from UserDefaults)
        let electrumConfigService = ElectrumConfigService()
        let electrumServer = electrumConfigService.getCurrentServer().url
        if !electrumServer.isEmpty { dict["electrumServer"] = electrumServer }

        let rgsConfigService = RgsConfigService()
        let rgsServerUrl = rgsConfigService.getCurrentServerUrl()
        if !rgsServerUrl.isEmpty { dict["rgsServerUrl"] = rgsServerUrl }

        // Dev Mode (computed value)
        dict["isDevModeEnabled"] = Env.isDebug && Env.network != .bitcoin

        return dict
    }

    /// Restores settings dictionary to UserDefaults
    func restoreSettingsDictionary(_ dict: [String: Any]) {
        // Special handling for coin selection (Android format)
        if let coinSelectAuto = dict["coinSelectAuto"] as? Bool {
            // Convert Android coinSelectAuto (false/true) to iOS coinSelectionMethod ("manual"/"autopilot")
            let methodString = coinSelectAuto ? "autopilot" : "manual"
            defaults.set(methodString, forKey: "coinSelectionMethod")
        }

        if let coinSelectPreference = dict["coinSelectPreference"] as? String {
            // Convert Android coinSelectPreference to iOS coinSelectionAlgorithm
            let iosAlgorithm = Self.convertAndroidPreferenceToIosAlgorithm(coinSelectPreference)
            defaults.set(iosAlgorithm, forKey: "coinSelectionAlgorithm")
        }

        // Process all settings keys (excluding server settings which need special handling)
        for (iosKey, type) in Self.settingsKeyTypes {
            // Skip coin selection keys as they're handled above
            if iosKey == "coinSelectionMethod" || iosKey == "coinSelectionAlgorithm" {
                continue
            }

            // Check both iOS key and Android key (in case backup came from Android)
            let androidKey = Self.iosToAndroidFieldMapping[iosKey] ?? iosKey

            // Try Android key first (for cross-platform restore), then iOS key
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
                // Handle type conversion: Android uses Int for quickPayAmount, Long for timestamps
                if let doubleValue = value as? Double {
                    defaults.set(doubleValue, forKey: iosKey)
                } else if let intValue = value as? Int {
                    // Convert Int to Double (for quickPayAmount, timestamps in milliseconds)
                    defaults.set(Double(intValue), forKey: iosKey)
                } else if let longValue = value as? Int64 {
                    // Convert Long (Int64) to Double (for timestamps)
                    defaults.set(Double(longValue), forKey: iosKey)
                }

            case .int:
                if let intValue = value as? Int {
                    defaults.set(intValue, forKey: iosKey)
                } else if let doubleValue = value as? Double {
                    // Convert Double to Int if needed
                    defaults.set(Int(doubleValue), forKey: iosKey)
                }

            case .stringArray:
                if let arrayValue = value as? [String] {
                    defaults.set(arrayValue, forKey: iosKey)
                }
            }
        }

        // Server settings (restore via services, not directly to UserDefaults)
        if let electrumServerUrl = dict["electrumServer"] as? String, !electrumServerUrl.isEmpty {
            let components = electrumServerUrl.split(separator: ":")
            if components.count >= 2 {
                let host = String(components[0])
                let portString = String(components[1])

                let electrumConfigService = ElectrumConfigService()
                let protocolType = electrumConfigService.getProtocolForPort(portString)

                let server = ElectrumServer(host: host, portString: portString, protocolType: protocolType)
                electrumConfigService.saveServerConfig(server)
                Logger.debug("Restored Electrum server: \(electrumServerUrl)", context: "SettingsStore")
            }
        }

        if let rgsServerUrl = dict["rgsServerUrl"] as? String, !rgsServerUrl.isEmpty {
            let rgsConfigService = RgsConfigService()
            rgsConfigService.saveServerUrl(rgsServerUrl)
            Logger.debug("Restored RGS server URL: \(rgsServerUrl)", context: "SettingsStore")
        }
    }
}
