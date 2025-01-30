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
}
