@testable import Bitkit
import BitkitCore
import Foundation
import Paykit
import XCTest

final class PaykitRequestPricingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFixedRatesDetermineExactAmountsWithoutMarketRates() throws {
        let pricing = PaykitRequestPricing(conversion: .fixed(rates: [
            ConversionRate(asset: "btc", value: "0.000012345"), ConversionRate(asset: "usdt", value: "1"),
        ]))
        let requested = try PaykitAmount(asset: .usd, value: "0.05")
        XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "btc-bitcoin-p2wpkh", period: nil, at: now).amount.atomic, 62)
        XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: nil, at: now).amount.atomic, 50000)
        XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "usd-bank-account", period: nil, at: now).amount, requested)
        XCTAssertThrowsError(try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: nil, at: now, quoteId: "unknown"))
    }

    func testFixedPricingSelectsTheRailBeforeTheAssetIncludingSameAssetPayments() throws {
        let requested = try PaykitAmount(asset: .btc, value: "1")
        let rates = [ConversionRate(asset: "btc", value: "2"), ConversionRate(asset: "btc-lightning", value: "0.5")]
        for values in [rates, Array(rates.reversed())] {
            let pricing = PaykitRequestPricing(conversion: .fixed(rates: Array(values)))
            XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "btc-lightning-bolt11", period: nil, at: now).amount.value, "0.5")
            XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "btc-lightning-lnurl", period: nil, at: now).amount.value, "0.5")
            XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "btc-bitcoin-p2wpkh", period: nil, at: now).amount.value, "2")
        }
        let pricing = PaykitRequestPricing(conversion: .fixed(rates: [rates[1]]))
        XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "btc-bitcoin-p2wpkh", period: nil, at: now).amount, requested)
    }

    func testPaymentMarketValueIsIndependentOfTheRequestedValue() throws {
        let pricing = PaykitRequestPricing(conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.001")]))
        let requested = try PaykitAmount(asset: .usd, value: "1000")
        let payment = try pricing.payment(requested: requested, endpoint: "btc-bitcoin-p2wpkh", period: nil, at: now)
        XCTAssertEqual(payment.amount.value, "1")
        let valuation = try payment.amount.converted(to: .usd, rate: PaykitExchangeRate(price: "2000", timestamp: now), at: now)
        XCTAssertEqual(valuation.value, "2000")
        XCTAssertEqual(requested.value, "1000")
    }

    func testSameAssetRecurringPaymentsUseParityAndOptionalQuoteValidity() throws {
        let requested = try PaykitAmount(asset: .btc, value: "1")
        let period = PaykitBillingPeriod(startsAt: now, endsAt: now.addingTimeInterval(86400))
        let quote = PaymentConversionQuoteRecord(eventId: "quote", billingPeriod: period.sdkValue,
                                                 rates: [ConversionRate(asset: "usdt", value: "100000")],
                                                 validFrom: period.sdkValue.startsAt,
                                                 expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(60)), outboundStatus: nil)
        let pricing = PaykitRequestPricing(conversion: .perPeriod, quotes: [quote])
        let unquoted = try pricing.payment(requested: requested, endpoint: "btc-lightning-bolt11", period: period, at: now)
        XCTAssertEqual(unquoted.amount, requested)
        XCTAssertNil(unquoted.quoteId)
        let quoted = try pricing.payment(requested: requested, endpoint: "btc-lightning-bolt11", period: period, at: now, quoteId: "quote")
        XCTAssertEqual(quoted.amount, requested)
        XCTAssertEqual(quoted.quoteId, "quote")
        XCTAssertFalse(quoted.isValid(at: now.addingTimeInterval(-1)))
        XCTAssertTrue(quoted.isValid(at: now.addingTimeInterval(60)))
        XCTAssertFalse(quoted.isValid(at: now.addingTimeInterval(61)))
        XCTAssertThrowsError(try pricing.payment(requested: requested, endpoint: "btc-lightning-bolt11", period: period, at: now, quoteId: "unknown"))
    }

    func testSubscriptionsKeepOnePaymentCurrencyAcrossBillingPeriods() throws {
        let bitcoin = PublicPaykitService.MethodId.onchainMethodId(network: Env.network, scriptType: .p2wpkh).rawValue
        let lightning = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
        let usdt = PublicPaykitService.MethodId.usdtArbitrum.rawValue
        let available = [bitcoin, lightning, usdt]
        for (asset, endpoints) in [(PaykitAsset.btc, [bitcoin, lightning]), (.usd, [usdt])] {
            let selected = PaykitRequestPricing.subscriptionEndpoints(requested: asset, available: available)
            XCTAssertEqual(selected, endpoints)
            XCTAssertTrue(PaykitRequestPricing.subscriptionEndpoints(requested: asset, available: available.filter { !endpoints.contains($0) })
                .isEmpty)
            let rates = try PaykitRequestPricing.rates(requested: asset, endpoints: selected, market: nil, at: now)
            let pricing = PaykitRequestPricing(conversion: rates.isEmpty ? nil : .fixed(rates: rates))
            let requested = try PaykitAmount(asset: asset, value: "5")
            let nextPeriod = PaykitBillingPeriod(startsAt: now.addingTimeInterval(31 * 86400), endsAt: now.addingTimeInterval(62 * 86400))
            let payment = try pricing.payment(requested: requested, endpoint: endpoints[0], period: nextPeriod, at: nextPeriod.startsAt)
            XCTAssertEqual(payment.amount.value, "5")
            XCTAssertNil(payment.quoteId)
            XCTAssertNil(payment.expiresAt)
            XCTAssertTrue(payment.isValid(at: nextPeriod.endsAt))
        }
        XCTAssertTrue(PaykitRequestPricing.subscriptionEndpoints(requested: .usdt, available: available).isEmpty)
    }

    func testMissingTermsOrRateNeverImplicitlyEnableConversion() throws {
        let requested = try PaykitAmount(asset: .usd, value: "5")
        for pricing in [PaykitRequestPricing(), PaykitRequestPricing(conversion: .fixed(rates: [ConversionRate(asset: "btc", value: "0.00001")]))] {
            XCTAssertThrowsError(try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: nil, at: now))
            XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "usd-bank-account", period: nil, at: now).amount, requested)
        }
    }

    func testQuotedArithmeticRejectsOverflowAndRoundsOnlyOnce() throws {
        let requested = try PaykitAmount(asset: .btc, value: "0.00000001")
        XCTAssertEqual(try requested.quoted(to: .usdt, multiplier: "123456.789012345678").atomic, 1235)
        XCTAssertThrowsError(try PaykitAmount(asset: .usdt, atomic: .max).quoted(to: .usdt, multiplier: "2"))
        for rate in ["0", "-1", "NaN", "1e2", "0.123456789012345678901234567890123456789"] {
            XCTAssertThrowsError(try requested.quoted(to: .usdt, multiplier: rate))
        }
    }

    func testRatesAreRequiredOnlyWhenIssuingBitcoinConversions() throws {
        let usd = PublicPaykitService.MethodId.usdtArbitrum.rawValue
        XCTAssertEqual(try PaykitRequestPricing.rates(requested: .usd, endpoints: [usd], market: nil, at: now),
                       [ConversionRate(asset: "usdt", value: "1")])
        XCTAssertThrowsError(try PaykitRequestPricing.rates(requested: .btc, endpoints: [usd], market: nil, at: now))
        let stale = PaykitExchangeRate(price: "100000", timestamp: now.addingTimeInterval(-601))
        XCTAssertThrowsError(try PaykitRequestPricing.rates(requested: .btc, endpoints: [usd], market: stale, at: now))
    }

    @MainActor
    func testProofEnvelopeFitsBeforeSending() throws {
        let binding = UsdtPaymentProofBinding(payer: String(repeating: "y", count: 52), payee: String(repeating: "y", count: 52),
                                              paymentAppId: "bitkit",
                                              paymentRequestId: UUID().uuidString.lowercased(),
                                              paymentReference: "invoice", paymentEndpointIdentifier: "usdt-arbitrum-address",
                                              periodStartsAt: "2027-01-01T00:00:00Z",
                                              periodEndsAt: "2027-02-01T00:00:00Z", conversionQuoteId: UUID().uuidString.lowercased())
        XCTAssertNoThrow(try PaykitUsdtPaymentService.validateProofSize(binding: binding))
        var oversized = binding
        oversized.paymentReference = String(repeating: "é", count: 256)
        XCTAssertThrowsError(try PaykitUsdtPaymentService.validateProofSize(binding: oversized))
    }

    func testRecurringPaymentsKeepTheirChosenQuoteAndInclusiveDeadline() throws {
        let period = PaykitBillingPeriod(startsAt: now, endsAt: now.addingTimeInterval(86400))
        let first = PaymentConversionQuoteRecord(eventId: "first", billingPeriod: period.sdkValue,
                                                 rates: [ConversionRate(asset: "usdt", value: "100000")], validFrom: period.sdkValue.startsAt,
                                                 expiresAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(60)), outboundStatus: nil)
        var later = first
        later.eventId = "later"
        later.rates = [ConversionRate(asset: "usdt", value: "110000")]
        let pricing = PaykitRequestPricing(conversion: .perPeriod, deadline: .periodStart(seconds: 30), quotes: [first, later])
        let requested = try PaykitAmount(asset: .btc, value: "0.00001")
        let selected = try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: period, at: now)
        XCTAssertEqual(selected.amount.value, "1.1")
        XCTAssertEqual(selected.quoteId, "later")
        let pinned = try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: period, at: now, quoteId: "first")
        XCTAssertEqual(pinned.amount.value, "1")
        XCTAssertTrue(pinned.isValid(at: now.addingTimeInterval(30)))
        XCTAssertFalse(pinned.isValid(at: now.addingTimeInterval(31)))
        XCTAssertFalse(pinned.isValid(at: now.addingTimeInterval(-1)))
        XCTAssertEqual(try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: period,
                                           at: now.addingTimeInterval(600), quoteId: "first"), pinned)
        XCTAssertThrowsError(try pricing.payment(
            requested: requested,
            endpoint: "usdt-arbitrum-address",
            period: period,
            at: now,
            quoteId: "missing"
        ))
        XCTAssertThrowsError(try pricing.payment(requested: requested, endpoint: "usdt-arbitrum-address", period: nil, at: now))
    }
}
