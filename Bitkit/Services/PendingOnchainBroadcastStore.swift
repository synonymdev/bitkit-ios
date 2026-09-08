import Foundation
import LDKNode

struct PendingOnchainBroadcastIntent: Codable, Equatable {
    var activeTxid: Txid
    var lineage: [Txid]

    init(activeTxid: Txid, lineage: [Txid]) {
        self.activeTxid = activeTxid
        self.lineage = Array(Set(lineage + [activeTxid])).sorted()
    }

    func contains(_ txid: Txid) -> Bool {
        activeTxid == txid || lineage.contains(txid)
    }
}

protocol PendingOnchainBroadcastStoring: AnyObject {
    func intents(walletIndex: Int) -> [PendingOnchainBroadcastIntent]
    func record(_ intent: PendingOnchainBroadcastIntent, walletIndex: Int)
    func remove(matching txid: Txid, walletIndex: Int)
}

final class PendingOnchainBroadcastStore: PendingOnchainBroadcastStoring {
    static let shared = PendingOnchainBroadcastStore()

    private struct State: Codable {
        var wallets: [String: [PendingOnchainBroadcastIntent]]
    }

    private let defaults: UserDefaults
    private let key = "pendingOnchainBroadcastIntents"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func intents(walletIndex: Int) -> [PendingOnchainBroadcastIntent] {
        state().wallets[String(walletIndex)] ?? []
    }

    func record(_ intent: PendingOnchainBroadcastIntent, walletIndex: Int) {
        var state = state()
        let walletKey = String(walletIndex)
        var intents = state.wallets[walletKey] ?? []
        let matchingIndexes = intents.indices.filter { existingIndex in
            let existing = intents[existingIndex]
            return existing.contains(intent.activeTxid) || intent.lineage.contains(where: existing.contains)
        }
        let mergedLineage = matchingIndexes.reduce(into: intent.lineage) { result, index in
            result.append(contentsOf: intents[index].lineage)
            result.append(intents[index].activeTxid)
        }
        for index in matchingIndexes.reversed() {
            intents.remove(at: index)
        }
        intents.append(PendingOnchainBroadcastIntent(activeTxid: intent.activeTxid, lineage: mergedLineage))
        state.wallets[walletKey] = intents
        save(state)
    }

    func remove(matching txid: Txid, walletIndex: Int) {
        var state = state()
        let walletKey = String(walletIndex)
        guard var intents = state.wallets[walletKey] else { return }
        intents.removeAll { $0.contains(txid) }
        if intents.isEmpty {
            state.wallets.removeValue(forKey: walletKey)
        } else {
            state.wallets[walletKey] = intents
        }
        save(state)
    }

    private func state() -> State {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State(wallets: [:]) }
        return state
    }

    private func save(_ state: State) {
        guard !state.wallets.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
