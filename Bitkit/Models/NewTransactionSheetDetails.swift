//
//  NewTransactionSheetDetails.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import Foundation

struct NewTransactionSheetDetails: Codable {
    enum NewTransactionSheetType: Codable {
        case onchain
        case lightning
    }

    enum NewTransactionSheetDirection: Codable {
        case sent
        case received
    }

    let type: NewTransactionSheetType
    let direction: NewTransactionSheetDirection
    let sats: UInt64

    private static let appGroupUserDefaults = UserDefaults(suiteName: "group.bitkit")

    func save() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self)
            Self.appGroupUserDefaults?.set(data, forKey: "backgroundTransaction")
        } catch {
            Logger.error(error, context: "Failed to cache transaction")
        }
    }

    static func load() -> NewTransactionSheetDetails? {
        guard let data = appGroupUserDefaults?.data(forKey: "backgroundTransaction") else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(NewTransactionSheetDetails.self, from: data)
        } catch {
            Logger.error(error, context: "Failed to load cached transaction")
            return nil
        }
    }

    static func clear() {
        appGroupUserDefaults?.removeObject(forKey: "backgroundTransaction")
    }
}
