//
//  BlocktankViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

@MainActor
class BlocktankViewModel: ObservableObject {
    @Published var orders: [BtOrder] = [] // TODO: cache orders to disk
    @Published var cJitEntries: [CJitEntry] = [] // TODO: cache cJitEntries
    @Published var info: BtInfo? = nil // TODO: cache this

    @AppStorage("cjitActive") var cjitActive = false

    func refreshInfo() async throws {
        info = try await BlocktankService.shared.getInfo()
    }

    func createCjit(amountSats: UInt64, description: String) async throws -> CJitEntry {
        guard let nodeId = LightningService.shared.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let entry = try await BlocktankService.shared.createCJitEntry(
            channelSizeSat: amountSats * 2, // TODO: check this amount default from RN app
            invoiceSat: amountSats,
            invoiceDescription: description,
            nodeId: nodeId,
            channelExpiryWeeks: 2, // TODO: check this amount default from RN app
            options: .init()
        )

        cJitEntries.append(entry)

        return entry
    }

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
        options.clientBalanceSat = spendingBalanceSats
        options.zeroReserve = true
        options.zeroConf = true
        options.zeroConfPayment = false

        let order = try await BlocktankService.shared.createOrder(
            lspBalanceSat: receivingBalanceSats,
            channelExpiryWeeks: channelExpiryWeeks,
            options: options
        )
        orders.append(order)

        return order
    }
}
