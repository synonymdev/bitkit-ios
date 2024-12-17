//
//  BlocktankTests.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/08/28.
//

import XCTest

final class BlocktankTests: XCTestCase {
    func testGetInfo() async throws {
        let info = try await BlocktankService.shared.getInfo()
        XCTAssertEqual(info.onchain.network, .regtest)
    }

    func testCreateCjitOrder() async throws {
        let channelSizeSat: UInt64 = 120000
        let invoiceSat: UInt64 = 6000
        let expiryWeeks: UInt8 = 2

        let cjit = try await BlocktankService.shared.createCJitEntry(
            channelSizeSat: channelSizeSat,
            invoiceSat: invoiceSat,
            invoiceDescription: "Pay me",
            nodeId: "0296b2db342fcf87ea94d981757fdf4d3e545bd5cef4919f58b5d38dfdd73bf5c9",
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
