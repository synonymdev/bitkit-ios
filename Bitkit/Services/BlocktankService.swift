//
//  BlocktankService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/01/30.
//

import Foundation

class BlocktankService {
    static var shared = BlocktankService()
    private init() {}

    func getInfo() async throws -> IBtInfo? {
        try await ServiceQueue.background(.blocktank) {
            try await Bitkit.getInfo(refresh: false)
        }
    }

    func createCjitEntry(
        channelSizeSat: UInt64,
        invoiceSat: UInt64,
        invoiceDescription: String,
        nodeId: String,
        channelExpiryWeeks: UInt32,
        options: CreateCjitOptions
    ) async throws -> IcJitEntry {
        try await ServiceQueue.background(.blocktank) {
            try await Bitkit.createCjitEntry(
                channelSizeSat: channelSizeSat,
                invoiceSat: invoiceSat,
                invoiceDescription: invoiceDescription,
                nodeId: nodeId,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    func getCjitEntries(entryIds: [String], filter: CJitStateEnum?, refresh: Bool) async throws -> [IcJitEntry] {
        try await ServiceQueue.background(.blocktank) {
            try await Bitkit.getCjitEntries(entryIds: entryIds, filter: filter, refresh: refresh)
        }
    }

    func createOrder(
        lspBalanceSat: UInt64,
        channelExpiryWeeks: UInt32,
        options: CreateOrderOptions
    ) async throws -> IBtOrder {
        try await ServiceQueue.background(.blocktank) {
            try await Bitkit.createOrder(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    func getOrders(orderIds: [String], filter: BtOrderState2?, refresh: Bool) async throws -> [IBtOrder] {
        try await ServiceQueue.background(.blocktank) {
            try await Bitkit.getOrders(orderIds: orderIds, filter: filter, refresh: refresh)
        }
    }
}
