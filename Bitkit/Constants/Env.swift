import BitkitCore
import Foundation
import LDKNode
import LocalAuthentication

enum Env {
    static let appName = "bitkit"

    static var isUsdtEnabled: Bool {
        (network == .bitcoin || isDebug) && usdtBundlerUrl != nil && usdtRpcUrl != nil
    }

    static var usdtBundlerUrl: String? {
        configValue("USDT_BUNDLER_URL")
    }

    static var usdtDepositsUrl: String? {
        configValue("USDT_DEPOSITS_URL")
    }

    static var usdtBridgesUrl: String? {
        configValue("USDT_BRIDGES_URL")
    }

    static var usdtRpcUrl: String? {
        configValue("USDT_RPC_URL")
    }

    static var usdtDestinations: [UsdtDestination] {
        let enabled = Set((configValue("USDT_BRIDGE_NETWORKS") ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let bridges: [(String, UsdtDestination)] = [
            ("ethereum", .ethereum), ("polygon", .polygon), ("plasma", .plasma), ("stable", .stable),
        ]
        return [.arbitrum] + bridges.filter { enabled.contains($0.0) }.map(\.1)
    }

    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    #if DEBUG
        static let isDebug = true
    #else
        static let isDebug = false
    #endif

    static var isE2E: Bool {
        #if E2E_BUILD
            return true
        #elseif DEBUG
            return ProcessInfo.processInfo.environment["E2E"] == "true"
        #else
            return false
        #endif
    }

    private static func infoPlistValue(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func configValue(_ key: String) -> String? {
        #if DEBUG || E2E_BUILD
            let envValue = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if envValue?.isEmpty == false {
                return envValue
            }
            if let argumentValue = launchArgumentValue(key) {
                return argumentValue
            }
        #endif
        return infoPlistValue(key)
    }

    private static func launchArgumentValue(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        for argument in arguments {
            for prefix in ["-\(key)=", "--\(key)=", "\(key)="] where argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        for (index, argument) in arguments.enumerated() where argument == "-\(key)" || argument == "--\(key)" || argument == key {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else { return "true" }
            let value = arguments[nextIndex]
            guard !value.hasPrefix("-") else { return "true" }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    private static func boolConfigValue(_ key: String) -> Bool {
        guard let value = configValue(key)?.lowercased() else { return false }
        return ["1", "true", "yes", "y"].contains(value)
    }

    private static var e2eBackend: String {
        (infoPlistValue("E2E_BACKEND") ?? "local").lowercased()
    }

    private static var isLocalE2EBackend: Bool {
        isE2E && e2eBackend == "local"
    }

    private static var e2eLocalHost: String {
        configValue("E2E_LOCAL_HOST") ?? "127.0.0.1"
    }

    private static var e2eHomegateUrl: String {
        infoPlistValue("E2E_HOMEGATE_URL") ?? "http://\(e2eLocalHost):6288"
    }

    static var e2eHomeserverPubky: String? {
        isLocalE2EBackend ? infoPlistValue("E2E_HOMESERVER_PUBKY") : nil
    }

    static var pubkyLocalTestnetHost: String? {
        isLocalE2EBackend ? e2eLocalHost : nil
    }

    private static var e2eNetwork: LDKNode.Network {
        switch (infoPlistValue("E2E_NETWORK") ?? "regtest").lowercased() {
        case "bitcoin", "mainnet":
            return .bitcoin
        case "testnet":
            return .testnet
        case "signet":
            return .signet
        default:
            return .regtest
        }
    }

    /// The current execution context of the app
    static var currentExecutionContext: ExecutionContext {
        let isNotificationExtension = Bundle.main.bundleIdentifier?.lowercased().contains("notification") == true
        return isNotificationExtension ? .pushNotificationExtension : .foregroundApp
    }

    /// {Team ID}.{Keychain Group}
    /// Returns the keychain access group based on the current network
    static var keychainGroup: String {
        let base = "KYH47R284B.to.bitkit"
        let networkSuffix = networkName
        return networkSuffix == "bitcoin" ? base : "\(base).\(networkSuffix)"
    }

    /// Keychain access group shared with Pubky Ring for cross-app pubky records
    static let sharedKeychainGroup = "KYH47R284B.pubky.shared"

    // MARK: wallet services

    /// Beignet primary run for the Lightning-first mainnet test, reached through a public TCP relay.
    private static let primaryNodeUriMainnet = "024a6cc632544189896cca8e06e375bdb1d1f34a71a4c25d09a39cf0ed920a299c@bore.pub:39101"

    /// The Lightning-first primary node: it funds channels just in time and grows them by splicing.
    /// A `PRIMARY_NODE_URI` config value overrides it, for regtest runs against a local primary.
    static var primaryNodeUri: String? {
        configValue("PRIMARY_NODE_URI") ?? (network == .bitcoin ? primaryNodeUriMainnet : nil)
    }

    static var primaryNode: LnPeer? {
        primaryNodeUri.flatMap { try? LnPeer(connection: $0) }
    }

    static let network: LDKNode.Network = {
        if isUnitTest {
            return .regtest
        }
        if isE2E {
            return e2eNetwork
        }
        if isDebug {
            return .regtest
        }
        return .bitcoin
    }()

    /// Whether LN -> onchain swaps can reach a Boltz backend. Boltz only serves a public API on
    /// mainnet: its testnet deployment is deprecated and regtest resolves to a local backend that
    /// no build of ours can reach. Elsewhere the transfer to savings closes a channel instead.
    static var isSwapSupported: Bool {
        network == .bitcoin
    }

    static let ldkLogLevel = LDKNode.LogLevel.trace

    static let walletSyncIntervalSecs: UInt64 = 10 // TODO: play around with this

    /// Converts the LDKNode.Network to BitkitCore.Network for use with bitkitcore functions
    static var bitkitCoreNetwork: BitkitCore.Network {
        switch network {
        case .bitcoin: .bitcoin
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }

    /// Lowercase storage/display name for the current network.
    static var networkName: String {
        networkName(for: network)
    }

    /// Lowercase storage/display name for a network.
    static func networkName(for network: LDKNode.Network) -> String {
        switch network {
        case .bitcoin: "bitcoin"
        case .testnet: "testnet"
        case .signet: "signet"
        case .regtest: "regtest"
        }
    }

    // MARK: Security settings

    static let pinAttempts = 8

    // MARK: Server URLs

    static func electrumServerUrl(for network: LDKNode.Network) -> String {
        switch network {
        case .bitcoin: return "ssl://bitkit.to:9999"
        case .signet: return "ssl://mempool.space:60602"
        case .testnet: return "ssl://electrum.blockstream.info:60002"
        case .regtest: return "ssl://electrs.bitkit.stag0.blocktank.to:9999"
        }
    }

    static var electrumServerUrl: String {
        if isE2E, e2eBackend == "local" {
            return "tcp://\(e2eLocalHost):60001"
        }
        return electrumServerUrl(for: network)
    }

    static var trezorBridgeEnabled: Bool {
        (isDebug || isE2E) && boolConfigValue("TREZOR_BRIDGE")
    }

    static var trezorBridgeUrl: String {
        configValue("TREZOR_BRIDGE_URL") ?? "http://127.0.0.1:21325"
    }

    static var trezorElectrumUrl: String? {
        guard isDebug || isE2E else { return nil }
        return configValue("TREZOR_ELECTRUM_URL")
    }

    static var isTrezorEmulatorTesting: Bool {
        #if TEST_TREZOR_EMU
            return isDebug || isE2E
        #else
            return (isDebug || isE2E) && boolConfigValue("TEST_TREZOR_EMU")
        #endif
    }

    static var shouldResetTrezorEmulatorState: Bool {
        isTrezorEmulatorTesting && boolConfigValue("TEST_TREZOR_RESET_STATE")
    }

    static var appStorageUrl: URL {
        // App group so files can be shared with extensions
        guard let documentsDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bitkit") else {
            fatalError("Could not find documents directory")
        }

        if isUnitTest {
            return documentsDirectory.appendingPathComponent("unit-tests")
        }

        return documentsDirectory
    }

    static func ldkStorage(walletIndex: Int) -> URL {
        appStorageUrl
            .appendingPathComponent(networkName)
            .appendingPathComponent("wallet\(walletIndex)/ldk")
    }

    static func bitkitCoreStorage(walletIndex: Int) -> URL {
        appStorageUrl
            .appendingPathComponent(networkName)
            .appendingPathComponent("wallet\(walletIndex)/core")
    }

    static var ldkRgsServerUrl: String? {
        switch network {
        case .bitcoin: "https://rgs.blocktank.to/snapshot"
        case .signet: "https://rapidsync.lightningdevkit.org/signet/snapshot"
        case .testnet: "https://rapidsync.lightningdevkit.org/testnet/snapshot"
        case .regtest: "https://bitkit.stag0.blocktank.to/rgs/snapshot"
        }
    }

    static var ldkScorerUrl: String? {
        switch network {
        case .bitcoin: "https://api.blocktank.to/scorer-prod"
        case .signet: nil
        case .testnet: nil
        case .regtest: "https://api.stag0.blocktank.to/scorer"
        }
    }

    static var blocktankBaseUrl: String {
        switch network {
        case .bitcoin: "https://api1.blocktank.to"
        default: "https://api.stag0.blocktank.to"
        }
    }

    static var blocktankClientServer: String {
        switch network {
        case .bitcoin: "\(blocktankBaseUrl)/api"
        default: "\(blocktankBaseUrl)/blocktank/api/v2"
        }
    }

    static var btcRatesServer: String {
        switch network {
        case .bitcoin: "https://api1.blocktank.to/api/fx/rates/btc"
        case .signet: "https://bitkit.stag0.blocktank.to/fx/rates/btc"
        case .testnet: "https://bitkit.stag0.blocktank.to/fx/rates/btc"
        case .regtest: "https://bitkit.stag0.blocktank.to/fx/rates/btc"
        }
    }

    static let fxRateRefreshInterval: TimeInterval = 2 * 60 // 2 minutes
    static let fxRateStaleThreshold: TimeInterval = 10 * 60 // After this we notify the user that the rates are stale due to a failed refresh

    static let blocktankOrderRefreshInterval: TimeInterval = 2 * 60 // 2 minutes

    static var vssStoreIdPrefix: String {
        "bitkit_v1_\(networkName)"
    }

    #if DEBUG || E2E_BUILD
        struct BackupTestEndpoints: Equatable {
            let vss: String
            let auth: String

            static func resolve(enabled: Bool, vss: String?, auth: String?) throws -> Self? {
                guard enabled else { return nil }
                let vss = vss?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let auth = auth?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !vss.isEmpty || !auth.isEmpty else { return nil }
                guard valid(vss), valid(auth) else { throw ConfigurationError.invalidBackupEndpoints }
                return Self(vss: vss, auth: auth)
            }

            private static func valid(_ value: String) -> Bool {
                guard let url = URLComponents(string: value),
                      url.scheme == "http" || url.scheme == "https", url.host == "localhost",
                      let port = url.port, (1 ... 65535).contains(port),
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      !url.path.isEmpty
                else { return false }
                return true
            }
        }

        enum ConfigurationError: Error {
            case invalidBackupEndpoints
        }

        private static var backupTestEndpoints: BackupTestEndpoints? {
            do {
                return try BackupTestEndpoints.resolve(
                    enabled: isE2E,
                    vss: configValue("E2E_VSS_SERVER_URL"),
                    auth: configValue("E2E_LNURL_AUTH_SERVER_URL")
                )
            } catch {
                preconditionFailure("E2E backup endpoints must be a valid pair of localhost URLs with explicit ports")
            }
        }
    #endif

    static var vssServerUrl: String {
        #if DEBUG || E2E_BUILD
            if let endpoints = backupTestEndpoints {
                return endpoints.vss
            }
        #endif
        switch network {
        case .bitcoin: return "https://bitkit.to/vss_rs_auth"
        default: return "https://bitkit.stag0.blocktank.to/vss_rs_auth"
        }
    }

    static var lnurlAuthServerUrl: String {
        #if DEBUG || E2E_BUILD
            if let endpoints = backupTestEndpoints {
                return endpoints.auth
            }
        #endif
        switch network {
        case .bitcoin: return "https://bitkit.to/lnurl_auth/auth"
        default: return "https://bitkit.stag0.blocktank.to/lnurl_auth/auth"
        }
    }

    static var rnBackupServerHost: String {
        switch network {
        case .bitcoin: "https://blocktank.synonym.to/backups-ldk"
        default: "https://bitkit.stag0.blocktank.to/backups-ldk"
        }
    }

    /// Homegate URL for auto-provisioned identity signup via IP verification.
    static var homegateUrl: String {
        if isLocalE2EBackend {
            return e2eHomegateUrl
        }

        switch network {
        case .bitcoin:
            return "https://homegate.pubky.app"
        default:
            return "https://homegate.staging.pubky.app"
        }
    }

    static var blockExplorerUrl: String {
        switch network {
        case .bitcoin: "https://mempool.space"
        case .signet: "https://mutinynet.com"
        case .testnet: "https://mempool.space/testnet"
        case .regtest: "https://mempool.bitkit.stag0.blocktank.to"
        }
    }

    static var logDirectory: String {
        appStorageUrl.appendingPathComponent("logs").path
    }

    static let dustLimit = 547
    static let msatsPerSat: UInt64 = 1000
    static let appStoreUrl = "https://apps.apple.com/app/bitkit-wallet/id6502440655"
    static let playStoreUrl = "https://play.google.com/store/apps/details?id=to.bitkit"
    static let githubUrl = "https://www.github.com/synonymdev/bitkit"
    static let githubReleasesUrl = "https://www.github.com/synonymdev/bitkit/releases"
    static var updaterUrl: String {
        isE2E
            ? "https://github.com/synonymdev/bitkit-e2e-tests/releases/download/updater/release.json"
            : "https://github.com/synonymdev/bitkit/releases/download/updater/release.json"
    }

    static let termsOfServiceUrl = "https://www.bitkit.to/terms-of-use"
    static let privacyPolicyUrl = "https://www.bitkit.to/privacy-policy"
    static let blocktankSunsetUrl = "https://blog.bitkit.to/"
    static let bitrefillRef = "AL6dyZYt"
    static let btcMapUrl = "https://btcmap.org/map"
    static let helpUrl = "https://help.bitkit.to"
    static let supportApiUrl = "https://synonym.to/api/chatwoot"

    // MARK: Biometric Authentication

    static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        return context.biometryType
    }
}
