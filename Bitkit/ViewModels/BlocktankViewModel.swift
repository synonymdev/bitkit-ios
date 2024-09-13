//
//  BlocktankViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

@MainActor
class BlocktankViewModel: ObservableObject {
    private init() {}
    public static var shared = BlocktankViewModel()

    @Published var orders: [BtOrder] = [] // TODO: cache orders to disk
    @Published var cJitEntries: [CJitEntry] = []

    func createOrder(spendingBalanceSats: UInt64, receivingBalanceSats _: UInt64? = nil, channelExpiryWeeks: UInt8 = 6) async throws -> BtOrder {
        guard let nodeId = LightningService.shared.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let receivingBalanceSats = spendingBalanceSats * 2 // TODO: confirm default in RN Bitkit

        let timestamp = Date().formatted(.iso8601)
        let signature = try await LightningService.shared.sign(message: "channelOpen-\(timestamp)")

        var options = CreateOrderOptions.initWithDefaults()
        options.wakeToOpen = .init(
            nodeId: nodeId,
            timestamp: timestamp,
            signature: signature
        )

        let order = try await BlocktankService.shared.createOrder(
            lspBalanceSat: receivingBalanceSats,
            channelExpiryWeeks: channelExpiryWeeks,
            options: options
        )
        orders.append(order)

        return order
    }
}
