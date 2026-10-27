import BigNumber
import BreezSdkSpark
import Foundation

/// The dollar token held on Spark, in 6-decimal dollar units like Arbitrum USDT so both format alike.
struct SparkUsdState: Equatable {
    let ticker: String
    let balance: UInt64
    var transfers: [SparkUsdTransfer] = []
}

struct SparkUsdTransfer: Identifiable, Equatable {
    let id: String
    let isIncoming: Bool
    let status: BreezSdkSpark.PaymentStatus
    let amount: UInt64
    let fee: UInt64
    let timestamp: UInt64
    let txHash: String
}

/// Where a dollar payment goes: a Spark address or invoice, with the amount an invoice fixes.
struct SparkUsdRecipient: Equatable {
    let request: String
    let amount: UInt64?
}

/// A priced conversion or bridge, ready to run. `pay` and `receive` are in sats for the bitcoin side and in dollar units
/// otherwise; `fee` is in the unit of what is paid, except for the bridge, where it is in dollar units.
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
