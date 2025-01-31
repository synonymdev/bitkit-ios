//
//  BlocktankTests.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/08/28.
//

@testable import Bitkit
import XCTest

final class BlocktankTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    let service = CoreService.shared.blocktank
    
    override func setUp() async throws {
        try await super.setUp()
        // Initialize the database before each test
        _ = try initDb(basePath: testDbPath)
        try await updateBlocktankUrl(newUrl: Env.blocktankClientServer)
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
    }
    
    func testGetInfo() async throws {
        // Test getting info with and without refresh
        guard let info = try await service.info() else {
            XCTFail("Info should not be nil")
            return
        }
        
        // Verify info structure
        // Test options
        XCTAssertGreaterThan(info.options.minChannelSizeSat, 0, "Minimum channel size should be greater than 0")
        XCTAssertGreaterThan(info.options.maxChannelSizeSat, info.options.minChannelSizeSat, "Maximum channel size should be greater than minimum")
        XCTAssertGreaterThan(info.options.minExpiryWeeks, 0, "Minimum expiry weeks should be greater than 0")
        XCTAssertGreaterThan(info.options.maxExpiryWeeks, info.options.minExpiryWeeks, "Maximum expiry weeks should be greater than minimum")
        
        // Test nodes
        XCTAssertFalse(info.nodes.isEmpty, "LSP nodes list should not be empty")
        for node in info.nodes {
            XCTAssertFalse(node.pubkey.isEmpty, "Node pubkey should not be empty")
            XCTAssertFalse(node.connectionStrings.isEmpty, "Node connection strings should not be empty")
        }
        
        // Test versions
        XCTAssertFalse(info.versions.http.isEmpty, "HTTP version should not be empty")
        XCTAssertFalse(info.versions.btc.isEmpty, "BTC version should not be empty")
        XCTAssertFalse(info.versions.ln2.isEmpty, "LN2 version should not be empty")
        
        // Test onchain info
        XCTAssertGreaterThan(info.onchain.feeRates.fast, 0, "Fast fee rate should be greater than 0")
        XCTAssertGreaterThan(info.onchain.feeRates.mid, 0, "Mid fee rate should be greater than 0")
        XCTAssertGreaterThan(info.onchain.feeRates.slow, 0, "Slow fee rate should be greater than 0")
    }
    
    func testCreateCjitOrder() async throws {
        // Test creating a CJIT order
        let channelSizeSat: UInt64 = 100_000 // 100k sats
        let invoiceSat: UInt64 = 10_000 // 10k sats for the invoice
        let invoiceDescription = "Test CJIT order"
        let nodeId = "03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad" // Example node ID
        let channelExpiryWeeks: UInt32 = 6
        let options = CreateCjitOptions(source: "bitkit", discountCode: nil)
        
        let cjitEntry = try await service.createCjit(
            channelSizeSat: channelSizeSat,
            invoiceSat: invoiceSat,
            invoiceDescription: invoiceDescription,
            nodeId: nodeId,
            channelExpiryWeeks: channelExpiryWeeks,
            options: options
        )
        
        // Verify CJIT entry
        XCTAssertNotNil(cjitEntry)
        XCTAssertFalse(cjitEntry.id.isEmpty, "CJIT entry ID should not be empty")
        XCTAssertEqual(cjitEntry.channelSizeSat, channelSizeSat, "Channel size should match requested amount")
        XCTAssertEqual(cjitEntry.source, "bitkit", "Source should be bitkit")
        XCTAssertNotNil(cjitEntry.lspNode, "LSP node should not be nil")
        XCTAssertFalse(cjitEntry.lspNode.pubkey.isEmpty, "LSP node pubkey should not be empty")
        XCTAssertEqual(cjitEntry.nodeId, nodeId, "Node ID should match requested ID")
        XCTAssertEqual(cjitEntry.channelExpiryWeeks, channelExpiryWeeks, "Channel expiry weeks should match")
       
        // Test getting CJIT entries
        let entries = try await service.getCjitOrders(entryIds: [cjitEntry.id], filter: nil, refresh: true)
        Logger.test("CjitEntries: \(entries.count)")
        XCTAssertFalse(entries.isEmpty, "Should retrieve created CJIT entry")
        XCTAssertEqual(entries.first?.id, cjitEntry.id, "Retrieved entry should match created entry")
    }
    
    func testOrders() async throws {
        // Test creating an order
        let lspBalanceSat: UInt64 = 100_000
        let channelExpiryWeeks: UInt32 = 2
        let options = CreateOrderOptions(
            clientBalanceSat: 0,
            lspNodeId: nil,
            couponCode: "",
            source: "bitkit-ios",
            discountCode: nil,
            turboChannel: false,
            zeroConfPayment: true,
            zeroReserve: false,
            clientNodeId: nil,
            signature: nil,
            timestamp: nil,
            refundOnchainAddress: nil,
            announceChannel: true
        )
        
        let order = try await service.newOrder(
            lspBalanceSat: lspBalanceSat,
            channelExpiryWeeks: channelExpiryWeeks,
            options: options
        )
        
        // Verify order
        XCTAssertNotNil(order)
        XCTAssertFalse(order.id.isEmpty, "Order ID should not be empty")
        XCTAssertEqual(order.state, .created, "Initial state should be created")
        XCTAssertEqual(order.state2, .created, "Initial state2 should be created")
        XCTAssertEqual(order.lspBalanceSat, lspBalanceSat, "LSP balance should match requested amount")
        XCTAssertEqual(order.clientBalanceSat, 0, "Client balance should be zero")
        XCTAssertEqual(order.channelExpiryWeeks, channelExpiryWeeks, "Channel expiry weeks should match")
        XCTAssertEqual(order.source, "bitkit-ios", "Source should be bitkit-ios")
        
        // Test getting orders
        let orders = try await service.orders(orderIds: [order.id], filter: nil, refresh: true)
        XCTAssertFalse(orders.isEmpty, "Orders list should not be empty")
        XCTAssertEqual(orders.first?.id, order.id, "Retrieved order should match created order")
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
}
