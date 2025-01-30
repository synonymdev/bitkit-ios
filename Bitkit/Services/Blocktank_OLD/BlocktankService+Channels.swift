//
//  BlocktankService+Channels.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import Foundation

extension BlocktankService_OLD {
    func openChannel(orderId: String) async throws {
        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        let params = [
            "connectionStringOrPubkey": nodeId,
            "announceChannel": false
        ] as [String: Any]

        let result = try await postRequest(Env.blocktankClientServer + "/channels/\(orderId)/open", params)
        Logger.info("Channel opened: \(String(data: result, encoding: .utf8) ?? "")")
    }
}
