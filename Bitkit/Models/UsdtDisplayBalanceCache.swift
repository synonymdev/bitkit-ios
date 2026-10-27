import CryptoKit
import Foundation

struct UsdtDisplayBalanceCache {
    private struct Record: Codable {
        let address: String
        let scope: String
        let balance: UInt64
    }

    private let defaults: UserDefaults
    private let scope: String
    private let key = "usdt_display_balance"

    init(storageDirectory: URL, rpcUrl: String?, bundlerUrl: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scope = SHA256.hash(data: Data("\(storageDirectory.path):\(rpcUrl ?? ""):\(bundlerUrl ?? "")".utf8)).description
    }

    func balance(for address: String) -> UInt64? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.address == address, record.scope == scope else { return nil }
        return record.balance
    }

    func save(_ balance: UInt64, address: String) {
        guard !address.isEmpty,
              let data = try? JSONEncoder().encode(Record(address: address, scope: scope, balance: balance)) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
