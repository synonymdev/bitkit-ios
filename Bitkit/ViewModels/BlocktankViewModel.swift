//
//  BlocktankViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

@MainActor
class BlocktankViewModel: ObservableObject {
    static let shared = BlocktankViewModel()

    @Published var orders: [BtOrder] = [] // TODO: cache orders to disk
    @Published var cJitEntries: [CJitEntry] = [] // TODO: cache cJitEntries
    @Published var info: BtInfo? = nil // TODO: cache this

    @AppStorage("cjitActive") var cjitActive = false

    private let blocktankService: BlocktankService
    private let lightningService: LightningService

    init(blocktankService: BlocktankService = .shared,
         lightningService: LightningService = .shared)
    {
        self.blocktankService = blocktankService
        self.lightningService = lightningService
    }

    func refreshInfo() async throws {
        info = try await blocktankService.getInfo()
    }

    func createCjit(amountSats: UInt64, description: String) async throws -> CJitEntry {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let entry = try await blocktankService.createCJitEntry(
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
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let receivingBalanceSats = spendingBalanceSats * 2 // TODO: confirm default in RN Bitkit
        let timestamp = Date().formatted(.iso8601)
        let signature = try await lightningService.sign(message: "channelOpen-\(timestamp)")

        var options = CreateOrderOptions_OLD.initWithDefaults()
        options.wakeToOpen = .init(
            nodeId: nodeId,
            timestamp: timestamp,
            signature: signature
        )
        options.clientBalanceSat = spendingBalanceSats
        options.zeroReserve = true
        options.zeroConf = true
        options.zeroConfPayment = false

        let order = try await blocktankService.createOrder(
            lspBalanceSat: receivingBalanceSats,
            channelExpiryWeeks: channelExpiryWeeks,
            options: options
        )
        orders.append(order)

        return order
    }
}
