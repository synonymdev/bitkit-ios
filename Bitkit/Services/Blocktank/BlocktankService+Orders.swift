//
//  BlocktankService+Orders.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import Foundation

extension BlocktankService {
    func createOrder(lspBalanceSat: UInt64, channelExpiryWeeks: UInt8, options: CreateOrderOptions) async throws -> BtOrder {
        var params: [String: Any] = [
            "lspBalanceSat": lspBalanceSat,
            "channelExpiryWeeks": channelExpiryWeeks,
            "clientBalanceSat": options.clientBalanceSat
        ]

        if let lspNodeId = options.lspNodeId {
            params["lspNodeId"] = lspNodeId
        }

        params["couponCode"] = options.couponCode

        if let source = options.source {
            params["source"] = source
        }

        if let discountCode = options.discountCode {
            params["discountCode"] = discountCode
        }

        params["zeroConf"] = options.zeroConf

        if let zeroConfPayment = options.zeroConfPayment {
            params["zeroConfPayment"] = zeroConfPayment
        }

        params["zeroReserve"] = options.zeroReserve

        if let wakeToOpen = options.wakeToOpen {
            params["wakeToOpen"] = [
                "nodeId": wakeToOpen.nodeId,
                "timestamp": wakeToOpen.timestamp,
                "signature": wakeToOpen.signature
            ]
        }

        if let nodeId = options.nodeId {
            params["nodeId"] = nodeId
        }

        if let refundOnchainAddress = options.refundOnchainAddress {
            params["refundOnchainAddress"] = refundOnchainAddress
        }

        let data = try await postRequest(Env.blocktankClientServer + "/channels", params)

        return try JSONDecoder().decode(BtOrder.self, from: data)
    }

    func getOrder(orderId: String) async throws -> BtOrder {
        let data = try await getRequest(Env.blocktankClientServer + "/channels/\(orderId)")
        return try JSONDecoder().decode(BtOrder.self, from: data)
    }

    func getOrders(orderIds: [String]) async throws -> [BtOrder] {
        let data = try await getRequest(Env.blocktankClientServer + "/channels", [
            "ids": orderIds
        ])
        return try JSONDecoder().decode([BtOrder].self, from: data)
    }
}
