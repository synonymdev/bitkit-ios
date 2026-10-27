import BigNumber
import BitkitCore
import BreezSdkSpark
import Foundation
import UserNotifications

/// The dollar token held on Spark, in 6-decimal dollar units like Arbitrum USDT so both format alike.
struct SparkUsdState: Equatable {
    let ticker: String
    let balance: UInt64
    var transfers: [SparkUsdTransfer] = []
}

/// Dollar activity on Spark. `amount` and `fee` are in dollar units; `sats` is the bitcoin side of a conversion, and
/// `counterparty` the Spark invoice a transfer paid or was paid through, when known.
struct SparkUsdTransfer: Identifiable, Hashable {
    enum Kind: Hashable {
        case sent
        case received
        case toUsd
        case toBtc
        case toArbitrum
    }

    let id: String
    let kind: Kind
    let status: BreezSdkSpark.PaymentStatus
    let amount: UInt64
    let fee: UInt64
    let timestamp: UInt64
    var txHash: String?
    var counterparty: String?
    var sats: UInt64?

    /// Whether dollars came in: a receive or a conversion to dollars.
    var isIncoming: Bool {
        kind == .received || kind == .toUsd
    }
}

/// Where a dollar payment goes: a Spark address or invoice, with the amount an invoice fixes.
struct SparkUsdRecipient: Equatable {
    let request: String
    let amount: UInt64?
}

/// A priced conversion or bridge, ready to run. `pay` and `receive` are in sats for the bitcoin side and in dollar units
/// otherwise; `fee` is always in dollar units.
struct SparkUsdQuote {
    enum Kind {
        case toUsd
        case toBtc
        case toArbitrum
    }

    let kind: Kind
    let pay: UInt64
    let receive: UInt64
    let fee: UInt64
    let prepared: PrepareSendPaymentResponse
}

enum SparkUsdError: Error {
    case unsupportedRecipient
    case noToken
    case noQuote
    case noRoute
}

enum SparkUsd {
    /// Shows a local notification for dollars received while the app is in the background.
    static func notifyReceived(amount: UInt64) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = t("usdt__received_title_spark")
            content.body = "$ " + usdtFormatAmount(amount: amount)
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "spark-usd-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    /// Decimals of Bitkit's dollar amounts, shared with Arbitrum USDT so both format alike.
    static let decimals = 6

    /// Arbitrum One, where Bitkit's own USDT wallet lives.
    static let arbitrumChainId = "42161"

    private static let inputPrefixes = ["spark1", "sparkrt1", "spark:"]

    /// Whether `input` looks like a Spark address or invoice, before the SDK parses it.
    static func isSparkInput(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inputPrefixes.contains { text.hasPrefix($0) }
    }

    /// Converts token base units to Bitkit's 6-decimal dollar units.
    static func toUsdUnits(_ amount: BInt, decimals tokenDecimals: Int) -> UInt64 {
        UInt64(scale(amount, from: tokenDecimals, to: decimals).description) ?? 0
    }

    /// Converts Bitkit's 6-decimal dollar units to token base units.
    static func fromUsdUnits(_ amount: UInt64, decimals tokenDecimals: Int) -> BInt {
        scale(BInt(String(amount)) ?? BInt(0), from: decimals, to: tokenDecimals)
    }

    private static func scale(_ value: BInt, from: Int, to: Int) -> BInt {
        guard from != to else { return value }
        let factor = (0 ..< abs(to - from)).reduce(BInt(1)) { result, _ in result * BInt(10) }
        return to > from ? value * factor : value / factor
    }
}
