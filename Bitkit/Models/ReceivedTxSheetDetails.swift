import Foundation

struct ReceivedTxSheetDetails: Codable {
    enum ReceivedTxType: Codable {
        case onchain
        case lightning
    }

    let type: ReceivedTxType
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

    static func load() -> ReceivedTxSheetDetails? {
        guard let data = appGroupUserDefaults?.data(forKey: "backgroundTransaction") else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ReceivedTxSheetDetails.self, from: data)
        } catch {
            Logger.error(error, context: "Failed to load cached transaction")
            return nil
        }
    }

    static func clear() {
        appGroupUserDefaults?.removeObject(forKey: "backgroundTransaction")
    }
}
