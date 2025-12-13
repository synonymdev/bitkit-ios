import BitkitCore
import Foundation
import LDKNode
import LocalAuthentication

enum Env {
    static let appName = "bitkit"

    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    #if targetEnvironment(simulator)
        static let isSim = true
    #else
        static let isSim = false
    #endif

    #if DEBUG
        static let isDebug = true
    #else
        static let isDebug = false
    #endif

    static var isE2E: Bool {
        #if E2E_BUILD
            return true
        #else
            return ProcessInfo.processInfo.environment["E2E"] == "true"
        #endif
    }

    static var isGeoblockingEnabled: Bool {
        #if CHECK_GEOBLOCK
            return true
        #else
            return ProcessInfo.processInfo.environment["GEO"] == "true"
        #endif
    }

    /// The current execution context of the app
    static var currentExecutionContext: ExecutionContext {
        return Bundle.main.bundleIdentifier?.lowercased().contains("notification") == true ? .pushNotificationExtension : .foregroundApp
    }

    // {Team ID}.{Keychain Group}
    /// Returns the keychain access group based on the current network
    static var keychainGroup: String {
        switch network {
        case .bitcoin:
            return "KYH47R284B.to.bitkit"
        case .testnet:
            return "KYH47R284B.to.bitkit.testnet"
        case .signet:
            return "KYH47R284B.to.bitkit.signet"
        case .regtest:
            return "KYH47R284B.to.bitkit.regtest"
        }
    }

    // MARK: wallet services

    static let network: LDKNode.Network = .bitcoin
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

    // MARK: Security settings

    static let pinAttempts = 8

    // MARK: Server URLs

    static var electrumServerUrl: String {
        if isE2E {
            return "tcp://127.0.0.1:60001"
        }

        switch network {
        case .bitcoin: return "ssl://fulcrum.bitkit.blocktank.to:8900"
        case .signet: return "ssl://mempool.space:60602"
        case .testnet: return "ssl://electrum.blockstream.info:60002"
        case .regtest: return "ssl://fulcrum.bitkit.stag0.blocktank.to:18484"
        }
    }

    static var esploraServerUrl: String {
        switch network {
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .signet:
            return "https://mutinynet.com/api"
        case .testnet:
            fatalError("Testnet network not implemented")
        case .regtest:
            return "https://bitkit.stag0.blocktank.to/electrs"
        }
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
        switch network {
        case .bitcoin:
            return
                appStorageUrl
                    .appendingPathComponent("bitcoin")
                    .appendingPathComponent("wallet\(walletIndex)/ldk")
        case .testnet:
            return
                appStorageUrl
                    .appendingPathComponent("testnet")
                    .appendingPathComponent("wallet\(walletIndex)/ldk")
        case .signet:
            return
                appStorageUrl
                    .appendingPathComponent("signet")
                    .appendingPathComponent("wallet\(walletIndex)/ldk")
        case .regtest:
            return
                appStorageUrl
                    .appendingPathComponent("regtest")
                    .appendingPathComponent("wallet\(walletIndex)/ldk")
        }
    }

    static func bitkitCoreStorage(walletIndex: Int) -> URL {
        switch network {
        case .bitcoin:
            return
                appStorageUrl
                    .appendingPathComponent("bitcoin")
                    .appendingPathComponent("wallet\(walletIndex)/core")
        case .signet:
            return
                appStorageUrl
                    .appendingPathComponent("signet")
                    .appendingPathComponent("wallet\(walletIndex)/core")
        case .testnet:
            return
                appStorageUrl
                    .appendingPathComponent("testnet")
                    .appendingPathComponent("wallet\(walletIndex)/core")
        case .regtest:
            return
                appStorageUrl
                    .appendingPathComponent("regtest")
                    .appendingPathComponent("wallet\(walletIndex)/core")
        }
    }

    static var ldkRgsServerUrl: String? {
        switch network {
        case .bitcoin: "https://rgs.blocktank.to/snapshot"
        // case .bitcoin: "https://rapidsync.lightningdevkit.org/snapshot/"
        case .signet: "https://rapidsync.lightningdevkit.org/signet/snapshot"
        case .testnet: "https://rapidsync.lightningdevkit.org/testnet/snapshot"
        case .regtest: "https://bitkit.stag0.blocktank.to/rgs/snapshot"
        }
    }

    // TODO: remove this to load from BT API instead
    static var trustedLnPeers: [LnPeer] {
        switch network {
        case .bitcoin:
            return [
                .init(nodeId: "039b8b4dd1d88c2c5db374290cda397a8f5d79f312d6ea5d5bfdfc7c6ff363eae3", host: "34.65.111.104", port: 9735),
                .init(nodeId: "03816141f1dce7782ec32b66a300783b1d436b19777e7c686ed00115bd4b88ff4b", host: "34.65.191.64", port: 9735),
                .init(nodeId: "02a371038863605300d0b3fc9de0cf5ccb57728b7f8906535709a831b16e311187", host: "34.65.186.40", port: 9735),
            ]
        case .signet:
            return []
        case .testnet:
            return []
        case .regtest:
            return [
                .init(nodeId: "028a8910b0048630d4eb17af25668cdd7ea6f2d8ae20956e7a06e2ae46ebcb69fc", host: "34.65.86.104", port: 9400),
            ]
        }
    }

    static var blocktankBaseUrl: String {
        switch network {
        case .bitcoin: "https://api1.blocktank.to/api"
        default: "https://api.stag0.blocktank.to/"
        }
    }

    static var blocktankPushNotificationServer: String {
        "\(blocktankBaseUrl)/notifications/api"
    }

    static var blocktankClientServer: String {
        switch network {
        case .bitcoin: "\(blocktankBaseUrl)"
        default: "\(blocktankBaseUrl)/blocktank/api/v2"
        }
    }

    static var btcRatesServer: String {
        switch network {
        case .bitcoin: "https://blocktank.synonym.to/fx/rates/btc"
        case .signet: "https://bitkit.stag0.blocktank.to/fx/rates/btc"
        case .testnet: "https://bitkit.stag0.blocktank.to/fx/rates/btc"
        case .regtest: "https://bitkit.stag0.blocktank.to/fx/rates/btc"
        }
    }

    static let fxRateRefreshInterval: TimeInterval = 2 * 60 // 2 minutes
    static let fxRateStaleThreshold: TimeInterval = 10 * 60 // After this we notify the user that the rates are stale due to a failed refresh

    static let blocktankOrderRefreshInterval: TimeInterval = 2 * 60 // 2 minutes

    static var pushNotificationFeatures: [BlocktankNotificationType] = [
        .incomingHtlc,
        .mutualClose,
        .orderPaymentConfirmed,
        .cjitPaymentArrived,
        .wakeToTimeout,
    ]

    static var vssStoreIdPrefix: String {
        switch network {
        case .bitcoin: "bitkit_v1_bitcoin"
        case .signet: "bitkit_v1_signet"
        case .testnet: "bitkit_v1_testnet"
        case .regtest: "bitkit_v1_regtest"
        }
    }

    static var vssServerUrl: String {
        return "http://localhost:5050/vss"
        // return "https://bitkit.stag0.blocktank.to/vss_rs"

        // switch network {
        // case .bitcoin: "https://bitkit.to/vss_rs_auth/"
        // default: "https://bitkit.stag0.blocktank.to/vss_rs_auth"
        // }
    }

    static var lnurlAuthServerUrl: String {
        return "http://localhost:5005/auth"
        // return ""

        // switch network {
        // case .bitcoin: "https://bitkit.to/lnurl_auth/auth"
        // default: "https://bitkit.stag0.blocktank.to/lnurl_auth/auth"
        // }
    }

    static var blockExplorerUrl: String {
        switch network {
        case .bitcoin: "https://mempool.space"
        case .signet: "https://mutinynet.com/"
        case .testnet: "https://mempool.space/testnet"
        case .regtest: "https://mempool.space" // TODO: switch to staging explorer when available
        }
    }

    static var logDirectory: String {
        return appStorageUrl.appendingPathComponent("logs").path
    }

    static let dustLimit = 547
    static let appStoreUrl = "https://apps.apple.com/app/bitkit-wallet/id6502440655"
    static let playStoreUrl = "https://play.google.com/store/apps/details?id=to.bitkit"
    static let githubUrl = "https://www.github.com/synonymdev/bitkit"
    static let githubReleasesUrl = "https://www.github.com/synonymdev/bitkit/releases"
    static let updaterUrl = "https://github.com/synonymdev/bitkit/releases/download/updater/release.json"
    static let termsOfServiceUrl = "https://www.bitkit.to/terms-of-use"
    static let privacyPolicyUrl = "https://www.bitkit.to/privacy-policy"
    static let geoCheckUrl = "https://api1.blocktank.to/api/geocheck"
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
