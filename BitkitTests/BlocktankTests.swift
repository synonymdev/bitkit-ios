//
//  BlocktankTests.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/08/28.
//

import XCTest

final class BlocktankTests: XCTestCase {
    override func setUp() async throws {
        try await LightningService.shared.setup(walletIndex: 0)
        try await LightningService.shared.start()
    }

    override func tearDown() async throws {
        // Stopping is better but it seems to take so long
//        try await LightningService.shared.stop()
    }

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
            nodeId: LightningService.shared.nodeId ?? "",
            channelExpiryWeeks: expiryWeeks,
            options: .init()
        )

        // Make sure respone matches the input
        XCTAssertEqual(channelSizeSat, cjit.channelSizeSat)
        XCTAssertEqual(expiryWeeks, cjit.channelExpiryWeeks)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
}
