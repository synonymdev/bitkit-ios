@testable import Bitkit
import BitkitCore
import Paykit
import XCTest

final class PaykitRouteSettlingTests: XCTestCase {
    private let onchain = PaykitEndpoint(methodId: "btc-regtest-p2wpkh", value: "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x")

    @MainActor
    func testASparkLegIsRefusedWhileAnEarlierContactWithdrawalSettles() async {
        snapshotAppDefaultsDomain()
        SparkManager.pendingContactWithdrawal = SparkContactWithdrawal(
            address: "bcrt1qearlier",
            amountSats: 5000,
            contact: "earlier",
            startedAt: 1
        )
        let app = AppViewModel()
        defer { ToastWindowManager.shared.hideToast() }
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.selectedWalletToPayFrom = .lightning
        let onchain = onchain
        var quoted = false

        let outcome = await app.routeContactPayment(
            PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true),
            amountSats: 9000,
            source: .spending,
            lightningSpendableSats: 10000,
            onchainSpendableSats: 0,
            request: nil
        ) { route, amountSats, source, lightningSats, onchainSats in
            try await PaykitRouteService.route(
                route, amountSats: amountSats, source: source, lightningSpendableSats: lightningSats, onchainSpendableSats: onchainSats
            ) { _, amountSats in
                quoted = true
                return [ServiceRouteLeg(
                    service: SparkManager.routeService,
                    endpoint: onchain,
                    deliveredSat: amountSats,
                    debitSat: amountSats + 300,
                    atomicity: "trusted",
                    validUntilUnix: 0
                )]
            }
        }

        XCTAssertEqual(outcome, .refused, "Spark takes one contact withdrawal at a time, so Confirm must not offer a second")
        XCTAssertFalse(quoted, "No Spark leg is quoted while the earlier withdrawal's journal is open")
        XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "PaykitRouteSettlingToast")
    }

    @MainActor
    func testAShortBalanceNamesItselfBeforeASettlingWithdrawal() async {
        snapshotAppDefaultsDomain()
        SparkManager.pendingContactWithdrawal = SparkContactWithdrawal(
            address: "bcrt1qearlier",
            amountSats: 5000,
            contact: "earlier",
            startedAt: 1
        )
        let app = AppViewModel()
        defer { ToastWindowManager.shared.hideToast() }
        app.contactPaymentContext = ContactPaymentContext(publicKey: "contact", privatePaymentContext: nil, endpoints: [])
        app.selectedWalletToPayFrom = .lightning

        let outcome = await app.routeContactPayment(
            PaykitRouteUi(endpoints: [onchain], offersSparkLeg: true),
            amountSats: 20000,
            source: .spending,
            lightningSpendableSats: 10000,
            onchainSpendableSats: 0,
            request: nil
        ) { route, amountSats, source, lightningSats, onchainSats in
            try await PaykitRouteService.route(
                route, amountSats: amountSats, source: source, lightningSpendableSats: lightningSats, onchainSpendableSats: onchainSats
            ) { _, _ in [] }
        }

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(
            ToastWindowManager.shared.currentToast?.accessibilityIdentifier,
            "PaykitRouteBalanceToast",
            "No balance covers 20,000, whatever an earlier withdrawal does, as on Android"
        )
    }
}
