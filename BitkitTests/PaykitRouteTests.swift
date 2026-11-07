@testable import Bitkit
import BitkitCore
import BreezSdkSpark
import XCTest

final class PaykitRouteTests: XCTestCase {
    private let onchain = PaykitEndpoint(methodId: "btc-regtest-p2wpkh", value: "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x")
    private let lightning = PaykitEndpoint(
        methodId: "btc-lightning-lnurl",
        value: "lnurl1dp68gurn8ghj7um9wfmxjcm99e3k7mf0v9cxj0m385ekvcenxc6r2c35xvukxefcv5mkvv34x5ekzd3ev56nyd3hxqurzepexejxxepnxscrvwfnv9nxzcn9xq6xyefhvgcxxcmyxymnserxfq5fns"
    )

    private func sparkLeg(amountSats: UInt64, feeSats: UInt64) -> ServiceRouteLeg {
        ServiceRouteLeg(
            service: SparkManager.routeService,
            endpoint: onchain,
            deliveredSat: amountSats,
            debitSat: amountSats + feeSats,
            atomicity: "trusted",
            validUntilUnix: UInt64(Date().timeIntervalSince1970) + 600
        )
    }

    // MARK: - Request

    func testSpendingOffersEveryEndpointAndSavingsOnlyTheOnchainOnes() {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: true)
        let leg = sparkLeg(amountSats: 20000, feeSats: 300)

        let spending = PaykitRouteService.request(
            route: route, amountSats: 20000, source: .spending, lightningSpendableSats: 50000, onchainSpendableSats: 90000,
            serviceLegs: [leg]
        )
        let savings = PaykitRouteService.request(
            route: route, amountSats: 20000, source: .savings, lightningSpendableSats: 50000, onchainSpendableSats: 90000,
            serviceLegs: [leg]
        )

        XCTAssertEqual(spending.contactEndpoints, [lightning, onchain])
        XCTAssertEqual(spending.lightningSpendableSat, 50000)
        XCTAssertEqual(spending.onchainSpendableSat, 0)
        XCTAssertEqual(spending.serviceLegs, [leg])
        XCTAssertEqual(savings.contactEndpoints, [onchain])
        XCTAssertEqual(savings.lightningSpendableSat, 0)
        XCTAssertEqual(savings.onchainSpendableSat, 90000)
        XCTAssertTrue(savings.serviceLegs.isEmpty)
    }

    // MARK: - Router outcomes

    func testRouterPaysTheLnurlEndpointItPicksFromSpending() throws {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: false)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20, source: .spending, lightningSpendableSats: 5000, onchainSpendableSats: 0,
                serviceLegs: []
            ),
            network: .regtest
        )

        XCTAssertEqual(picked, .direct(endpoint: lightning))
    }

    func testRouterPaysTheOnchainEndpointItPicksFromSavings() throws {
        let route = PaykitRouteUi(endpoints: [lightning, onchain], offersSparkLeg: false)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20000, source: .savings, lightningSpendableSats: 0, onchainSpendableSats: 90000,
                serviceLegs: []
            ),
            network: .regtest
        )

        XCTAssertEqual(picked, .direct(endpoint: onchain))
    }

    func testRouterTakesTheSparkLegToAnOnchainOnlyContactFromSpending() throws {
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true)
        let leg = sparkLeg(amountSats: 20000, feeSats: 300)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20000, source: .spending, lightningSpendableSats: 50000, onchainSpendableSats: 0,
                serviceLegs: [leg]
            ),
            network: .regtest
        )

        XCTAssertEqual(picked, .service(leg: leg))
        var routed = route
        routed.serviceLeg = leg
        XCTAssertEqual(routed.totalFeeSat, 300)
        XCTAssertEqual(routed.deliveredSat, 20000)
    }

    func testRouterFindsNoneWithoutABalanceThatReachesTheContact() throws {
        let route = PaykitRouteUi(endpoints: [onchain], offersSparkLeg: false)

        let picked = try paykitRoutePayment(
            request: PaykitRouteService.request(
                route: route, amountSats: 20000, source: .savings, lightningSpendableSats: 0, onchainSpendableSats: 5000,
                serviceLegs: []
            ),
            network: .regtest
        )

        guard case .none = picked else { return XCTFail("Expected no route, got \(picked)") }
        XCTAssertTrue(PaykitRouteService.isBalanceShort(amountSats: 20000, lightningSpendableSats: 0, onchainSpendableSats: 5000))
        XCTAssertFalse(PaykitRouteService.isBalanceShort(amountSats: 20000, lightningSpendableSats: 0, onchainSpendableSats: 90000))
    }

    // MARK: - Spark leg offer

    func testSparkLegIsOfferedForAnOnchainContactLightningCantPay() {
        let onchainOnly = ContactPaymentContext(
            publicKey: "contact",
            privatePaymentContext: nil,
            endpoints: [Self.endpoint(.regtestOnchainP2wpkh, onchain.value)]
        )

        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: true, canPayDirectly: false)?.offersSparkLeg,
            true
        )
        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: false, canPayDirectly: false)?.offersSparkLeg,
            false
        )
        XCTAssertEqual(
            PaykitRouteService.routeUi(for: onchainOnly, canRouteThroughSpark: true, canPayDirectly: true)?.offersSparkLeg,
            false
        )
        let usdtOnly = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [
            Self.endpoint(.usdtArbitrum, "0x0000000000000000000000000000000000000001"),
        ])
        XCTAssertNil(PaykitRouteService.routeUi(for: usdtOnly, canRouteThroughSpark: true, canPayDirectly: false))
    }

    // MARK: - Contact withdrawal journal

    func testJournaledWithdrawalSettlesFromTheMatchingSparkPayment() {
        let pending = SparkContactWithdrawal(address: onchain.value, amountSats: 20000, contact: "contact", startedAt: 1000)
        let other = Self.withdrawal(id: "other", to: "bcrt1qother", amountSats: 20000, timestamp: 1001)
        let earlier = Self.withdrawal(id: "earlier", to: onchain.value, amountSats: 20000, timestamp: 100)
        let sent = Self.withdrawal(id: "sent", to: onchain.value, amountSats: 20000, timestamp: 1001)

        XCTAssertEqual(SparkManager.matchingWithdrawal(pending, in: [other, earlier, sent])?.id, "sent")
        XCTAssertNil(SparkManager.matchingWithdrawal(pending, in: [other, earlier]))
    }

    func testSparkLegDebitsTheL1BroadcastFeeToo() {
        let fee = SendOnchainSpeedFeeQuote(userFeeSat: 750, l1BroadcastFeeSat: 1440)

        XCTAssertEqual(SparkManager.withdrawalDebitSats(amountSats: 2000, fee: fee), 4190, "Confirm and the fee check use 2,190, not 750")
        XCTAssertThrowsError(try SparkManager.checkWithdrawalFee(2190, shownFeeSats: 750))
    }

    func testContactWithdrawalStaysASendNotATransfer() {
        let toContact = Self.withdrawal(id: "contact", to: onchain.value, amountSats: 20000, timestamp: 1)
        let toSavings = Self.withdrawal(id: "savings", to: "bcrt1qsavings", amountSats: 5000, timestamp: 1)

        let transfers = SparkManager.savingsTransferTxIds(unclaimed: [], payments: [toContact, toSavings], contactWithdrawals: ["tx-contact"])

        XCTAssertEqual(transfers, ["tx-savings"])
    }

    private static func endpoint(_ methodId: PublicPaykitService.MethodId, _ value: String) -> PublicPaykitService.Endpoint {
        PublicPaykitService.Endpoint(methodId: methodId, value: value, min: nil, max: nil, rawPayload: value)
    }

    private static func withdrawal(id: String, to address: String, amountSats: UInt64, timestamp: UInt64) -> Payment {
        Payment(
            id: id,
            paymentType: .send,
            status: .completed,
            amount: U128(amountSats),
            fees: 300,
            timestamp: timestamp,
            method: .withdraw,
            details: .withdraw(txId: "tx-\(id)", vout: 0, destinationAddress: address),
            conversionDetails: nil
        )
    }
}
