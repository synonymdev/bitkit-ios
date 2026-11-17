@testable import Bitkit
import LDKNode
import XCTest

final class PrivatePaykitBolt11EndpointTests: XCTestCase {
    /// A signed, amount-less regtest invoice with no route hints, as a payee on the public graph issues. It carries its
    /// payee key and expires in 2126, so it decodes as payable.
    private static let invoiceWithoutRouteHints =
        "lnbcrt1p54twgqpp5htc0y8yrefcw5es9xg8367087kk32l9gc2h2fmg8tz5467kudfrssp5ecg6frsa968rzr22me7dxhgvpr0nseqqnc3pnlztqss05sypgjsqdqjvf5hg6mfwss8getnwsnp4qvs8zhz9xh4r7xhpecv4w24x5g8m5dsrxp878j9scz8amnkcqsd7vxq8zals8sqcqpj9qyysgqn2utpavus8d6ygcuks6pye4x62qvtskf0sq9f35hyhg6sqe28y6zt8ejmd09vepdptv66mnreevp9vchygkv733v2swje0zg2lrlqqsq834rkc"
    private static let paymentHash = "baf0f21c83ca70ea6605320f1d79e7f5ad157ca8c2aea4ed0758a95d7adc6a47"
    private static let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    private var previousNodePayments: (() async -> [LDKNode.PaymentDetails]?)!
    private var previousRailSupported: (() async -> Bool)!

    override func setUp() {
        super.setUp()
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let lightning = Bitkit.LightningService.shared
        previousNodePayments = lightning.nodePayments
        previousRailSupported = lightning.channelFreeRailSupported
        lightning.channelFreeRailSupported = { false }
    }

    override func tearDown() {
        let lightning = Bitkit.LightningService.shared
        lightning.nodePayments = previousNodePayments
        lightning.channelFreeRailSupported = previousRailSupported
        super.tearDown()
    }

    func testInvoiceWithoutRouteHintsIsPayable() async throws {
        let invoice = Self.invoiceWithoutRouteHints
        let parsed = try Bolt11Invoice.fromStr(invoiceStr: invoice)
        XCTAssertTrue(parsed.routeHints().isEmpty)
        XCTAssertEqual(String(parsed.paymentHash()), Self.paymentHash)
        Bitkit.LightningService.shared.nodePayments = { [] }
        let service = PrivatePaykitService()
        let endpoint = try bolt11Endpoint(invoice)
        await service.cacheResolvedEndpoints([endpoint], publicKey: Self.publicKey)

        let payable = await service.privatePayableEndpoints(from: [endpoint], publicKey: Self.publicKey)

        XCTAssertEqual(payable.map(\.value), [invoice])
        let cached = await service.cachedEndpoints(publicKey: Self.publicKey)
        XCTAssertEqual(cached?.count, 1)
    }

    func testAttemptedInvoiceWithoutRouteHintsIsDiscarded() async throws {
        let invoice = Self.invoiceWithoutRouteHints
        let hash = Self.paymentHash
        let attempt = LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: invoice),
            amountMsat: 1000, feePaidMsat: nil, direction: .outbound, status: .pending, latestUpdateTimestamp: 0
        )
        Bitkit.LightningService.shared.nodePayments = { [attempt] }
        let service = PrivatePaykitService()
        let endpoint = try bolt11Endpoint(invoice)
        await service.cacheResolvedEndpoints([endpoint], publicKey: Self.publicKey)

        let payable = await service.privatePayableEndpoints(from: [endpoint], publicKey: Self.publicKey)

        XCTAssertTrue(payable.isEmpty)
        let cached = await service.cachedEndpoints(publicKey: Self.publicKey)
        XCTAssertEqual(cached?.isEmpty, true)
    }

    private func bolt11Endpoint(_ invoice: String) throws -> PublicPaykitService.Endpoint {
        try PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningBolt11,
            value: invoice,
            min: nil,
            max: nil,
            rawPayload: PublicPaykitService.serializePayload(value: invoice)
        )
    }
}

private extension PrivatePaykitService {
    func cachedEndpoints(publicKey: String) -> [StoredPaymentEntry]? {
        state.contacts[publicKey]?.cachedResolvedEndpoints
    }
}
