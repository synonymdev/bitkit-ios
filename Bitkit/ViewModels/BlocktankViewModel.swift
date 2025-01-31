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
    @Published var info: IBtInfo? = nil

    @AppStorage("cjitActive") var cjitActive = false

    private let coreService: CoreService
    private let lightningService: LightningService

    init(coreService: CoreService = .shared,
         lightningService: LightningService = .shared)
    {
        self.coreService = coreService
        self.lightningService = lightningService
    }

    func refreshInfo() async throws {
        info = try await getInfo(refresh: false) // Instant set cached info to state before refreshing
        info = try await getInfo(refresh: true)
    }

    func createCjit(amountSats: UInt64, description _: String) async throws -> CJitEntry {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        return CJitEntry(
            id: UUID().uuidString,
            state: .created,
            feeSat: 1000,
            channelSizeSat: amountSats,
            channelExpiryWeeks: 6,
            channelOpenError: nil,
            nodeId: nodeId,
            invoice: .init(request: "", state: .canceled, expiresAt: "", updatedAt: ""),
            channel: nil,
            lspNode: .init(alias: "", pubkey: "", connectionStrings: []),
            couponCode: nil,
            source: "bitkit",
            discount: nil,
            expiresAt: "2024-03-20T12:00:00Z",
            updatedAt: "2024-03-19T12:00:00Z",
            createdAt: "2024-03-19T12:00:00Z"
        )
    }

    func createOrder(spendingBalanceSats: UInt64, receivingBalanceSats _: UInt64? = nil, channelExpiryWeeks _: UInt8 = 6) async throws -> BtOrder {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        return BtOrder(
            id: UUID().uuidString,
            state: .created,
            state2: .created,
            feeSat: 1000,
            lspBalanceSat: Int(spendingBalanceSats),
            clientBalanceSat: Int(spendingBalanceSats * 2),
            zeroConf: true,
            zeroReserve: false,
            wakeToOpenNodeId: nodeId,
            channelExpiryWeeks: 6,
            channelExpiresAt: "2024-03-20T12:00:00Z",
            orderExpiresAt: "2024-03-19T12:00:00Z",
            channel: nil,
            lspNode: LspNode(alias: "TestNode", pubkey: nodeId, connectionStrings: []),
            lnurl: nil,
            payment: .init(state: .created, state2: .created, paidSat: 1, bolt11Invoice: .init(request: "", state: .holding, expiresAt: "", updatedAt: ""), onchain: .init(address: "", confirmedSat: 1, requiredConfirmations: 1, transactions: [])),
            couponCode: nil,
            source: "bitkit",
            discount: nil,
            updatedAt: "2024-03-19T12:00:00Z",
            createdAt: "2024-03-19T12:00:00Z"
        )
    }
}
