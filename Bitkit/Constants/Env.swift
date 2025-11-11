import BitkitCore
import Foundation
import LDKNode
import LocalAuthentication

enum Env {
    static let appName = "bitkit"

    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #if E2E_BUILD
        static let isE2E = true
    #else
        static let isE2E = ProcessInfo.processInfo.environment["E2E"] == "true"
    #endif
    static let dustLimit = 547

    /// The current execution context of the app
    static var currentExecutionContext: ExecutionContext {
        return Bundle.main.bundleIdentifier?.lowercased().contains("notification") == true ? .pushNotificationExtension : .foregroundApp
    }

    // {Team ID}.{Keychain Group}
    static let keychainGroup = "KYH47R284B.to.bitkit" // TODO: needs to change for regtest/mainnet so we don't use same group

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

    // MARK: wallet services

    static let network: LDKNode.Network = .regtest
    static let walletSyncIntervalSecs: UInt64 = 10 // TODO: play around with this

    /// Converts the LDKNode.Network to BitkitCore.Network for use with bitkitcore functions
    static var bitkitCoreNetwork: BitkitCore.Network {
        switch network {
        case .bitcoin:
            return .bitcoin
        case .testnet:
            return .testnet
        case .signet:
            return .signet
        case .regtest:
            return .regtest
        }
    }

    // MARK: Security settings

    static let pinAttempts = 8

    // MARK: Server URLs

    static var electrumServerUrl: String {
        if isE2E {
            return "127.0.0.1:60001"
        }
        switch network {
        case .regtest:
            return "34.65.252.32:18483"
        case .bitcoin:
            return "35.187.18.233:18484"
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }

    static var esploraServerUrl: String {
        switch network {
        case .regtest:
            return "https://bitkit.stag0.blocktank.to/electrs"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
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
        case .regtest:
            return
                appStorageUrl
                    .appendingPathComponent("regtest")
                    .appendingPathComponent("wallet\(walletIndex)/ldk")
        case .bitcoin:
            return
                appStorageUrl
                    .appendingPathComponent("bitcoin")
                    .appendingPathComponent("wallet\(walletIndex)/ldk")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }

    static func bitkitCoreStorage(walletIndex: Int) -> URL {
        switch network {
        case .regtest:
            return
                appStorageUrl
                    .appendingPathComponent("regtest")
                    .appendingPathComponent("wallet\(walletIndex)/core")
        case .bitcoin:
            return
                appStorageUrl
                    .appendingPathComponent("bitcoin")
                    .appendingPathComponent("wallet\(walletIndex)/core")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }

    static var ldkRgsServerUrl: String? {
        switch network {
        case .regtest:
            return nil
        case .bitcoin:
            return "https://rapidsync.lightningdevkit.org/snapshot/"
        case .testnet:
            return nil
        case .signet:
            return nil
        }
    }

    // TODO: remove this to load from BT API instead
    static var trustedLnPeers: [LnPeer] {
        switch network {
        case .regtest:
            return [
                // Staging Blocktank node
                .init(nodeId: "028a8910b0048630d4eb17af25668cdd7ea6f2d8ae20956e7a06e2ae46ebcb69fc", host: "34.65.86.104", port: 9400),
            ]
        case .bitcoin:
            return []
        case .testnet:
            return []
        case .signet:
            return []
        }
    }

    static var blocktankBaseUrl: String {
        switch network {
        case .regtest:
            return "https://api.stag0.blocktank.to"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }

    static var blocktankPushNotificationServer: String {
        "\(blocktankBaseUrl)/notifications/api"
    }

    static var blocktankClientServer: String {
        "\(blocktankBaseUrl)/blocktank/api/v2"
    }

    static var btcRatesServer: String {
        "https://bitkit.stag0.blocktank.to/fx/rates/btc" // TODO: switch to prod when available
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

    static var vssServerUrl: String {
        switch network {
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        default:
            return "https://bitkit.stag0.blocktank.to/vss_rs_auth"
        }
    }

    static var vssStoreIdPrefix: String {
        switch network {
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .regtest:
            return "bitkit_v1_regtest"
        case .testnet:
            return "bitkit_v1_testnet"
        case .signet:
            return "bitkit_v1_signet"
        }
    }

    static var lnurlAuthServerUrl: String {
        switch network {
        case .bitcoin:
            fatalError("LNURL-auth server not implemented for mainnet")
        default:
            return "https://bitkit.stag0.blocktank.to/lnurl_auth/auth"
        }
    }

    static var logDirectory: String {
        return appStorageUrl.appendingPathComponent("logs").path
    }

    static var ldkLogLevel: LDKNode.LogLevel {
        return .trace
    }

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
