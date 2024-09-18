//
//  BlocktankTests.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/08/28.
//

import XCTest

final class BlocktankTests: XCTestCase {
    override func setUp() async throws {
        try? await LightningService.shared.wipeStorage(walletIndex: 0)
        try Keychain.wipeEntireKeychain()
        
        let mnemonic = "pool curve feature leader elite dilemma exile toast smile couch crane public"
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: mnemonic)

        try await LightningService.shared.setup(walletIndex: 0)
        try await LightningService.shared.start()
    }

    override func tearDown() async throws {
        // Stopping is better but it seems to take so long
        try await LightningService.shared.stop()
        try Keychain.delete(key: .bip39Mnemonic(index: 0))
    }

    func testGetInfo() async throws {
        let info = try await BlocktankService.shared.getInfo()
        XCTAssertEqual(info.onchain.network, .regtest)
    }

    func testCreateCjitOrder() async throws {
        let channelSizeSat: UInt64 = 120000
        let invoiceSat: UInt64 = 6000
        let expiryWeeks: UInt8 = 2

        guard let nodeId = LightningService.shared.nodeId else {
            XCTFail("Node id not available")
            return
        }

        let cjit = try await BlocktankService.shared.createCJitEntry(
            channelSizeSat: channelSizeSat,
            invoiceSat: invoiceSat,
            invoiceDescription: "Pay me",
            nodeId: nodeId,
            channelExpiryWeeks: expiryWeeks,
            options: .init()
        )

        // Make sure respone matches the input
        XCTAssertEqual(channelSizeSat, cjit.channelSizeSat)
        XCTAssertEqual(expiryWeeks, cjit.channelExpiryWeeks)

        let entry = try await BlocktankService.shared.getCJitEntry(entryId: cjit.id)
        XCTAssertEqual(cjit.id, entry.id)
        XCTAssertEqual(cjit.channelSizeSat, entry.channelSizeSat)

        Logger.test(cjit.invoice)
    }

    func testOrders() async throws {
        let order1 = try await BlocktankService.shared.createOrder(
            lspBalanceSat: 100000,
            channelExpiryWeeks: 2,
            options: .initWithDefaults()
        )

        let orderCheck = try await BlocktankService.shared.getOrder(orderId: order1.id)
        XCTAssertEqual(order1.id, orderCheck.id)
        XCTAssertEqual(order1.payment.onchain.address, orderCheck.payment.onchain.address)

        let order2 = try await BlocktankService.shared.createOrder(
            lspBalanceSat: 123400,
            channelExpiryWeeks: 4,
            options: .initWithDefaults()
        )

        let orders = try await BlocktankService.shared.getOrders(orderIds: [order1.id, order2.id])
        XCTAssertEqual(2, orders.count)
        XCTAssertEqual(order1.id, orders[0].id)
        XCTAssertEqual(order2.id, orders[1].id)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
}
