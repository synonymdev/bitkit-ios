//
//  BlocktankService+CJIT.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import Foundation

extension BlocktankService {
    func createCJitEntry(
        channelSizeSat: UInt64,
        invoiceSat: UInt64,
        invoiceDescription: String,
        nodeId: String,
        channelExpiryWeeks: UInt8,
        options: CreateCjitOptions
    ) async throws -> CJitEntry {
        var params: [String: Any] = [
            "channelSizeSat": channelSizeSat,
            "invoiceSat": invoiceSat,
            "invoiceDescription": invoiceDescription,
            "nodeId": nodeId,
            "channelExpiryWeeks": channelExpiryWeeks,
        ]

        if let source = options.source {
            params["source"] = source
        }

        if let discountCode = options.discountCode {
            params["discountCode"] = discountCode
        }

        let data = try await postRequest(Env.blocktankClientServer + "/cjit", params)

        return try JSONDecoder().decode(CJitEntry.self, from: data)
    }

    func getCJitEntry(entryId: String) async throws -> CJitEntry {
        let data = try await getRequest(Env.blocktankClientServer + "/cjit/\(entryId)")
        return try JSONDecoder().decode(CJitEntry.self, from: data)
    }
}
