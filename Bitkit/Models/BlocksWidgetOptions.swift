import Foundation

/// Options for configuring the in-app and home screen blocks widgets (shared via App Group for the extension).
struct BlocksWidgetOptions: Codable, Equatable {
    var height: Bool = true
    var time: Bool = true
    var date: Bool = true
    var transactionCount: Bool = false
    var size: Bool = false
    var weight: Bool = false
    var difficulty: Bool = false
    var hash: Bool = false
    var merkleRoot: Bool = false
    var showSource: Bool = false

    private static let fieldLabels: [String: String] = [
        "height": "Block",
        "time": "Time",
        "date": "Date",
        "transactionCount": "Transactions",
        "size": "Size",
        "weight": "Weight",
        "difficulty": "Difficulty",
        "hash": "Hash",
        "merkleRoot": "Merkle Root",
    ]

    /// Rows to show, in stable order (matches in-app `BlocksWidget`).
    func displayRows(for data: BlockData) -> [(key: String, label: String, value: String)] {
        var items: [(key: String, label: String, value: String)] = []

        if height {
            items.append((key: "height", label: Self.fieldLabels["height"]!, value: data.height))
        }
        if time {
            items.append((key: "time", label: Self.fieldLabels["time"]!, value: data.time))
        }
        if date {
            items.append((key: "date", label: Self.fieldLabels["date"]!, value: data.date))
        }
        if transactionCount {
            items.append((key: "transactionCount", label: Self.fieldLabels["transactionCount"]!, value: data.transactionCount))
        }
        if size {
            items.append((key: "size", label: Self.fieldLabels["size"]!, value: data.size))
        }
        if weight {
            items.append((key: "weight", label: Self.fieldLabels["weight"]!, value: data.weight))
        }
        if difficulty {
            items.append((key: "difficulty", label: Self.fieldLabels["difficulty"]!, value: data.difficulty))
        }
        if hash {
            items.append((key: "hash", label: Self.fieldLabels["hash"]!, value: data.hash))
        }
        if merkleRoot {
            items.append((key: "merkleRoot", label: Self.fieldLabels["merkleRoot"]!, value: data.merkleRoot))
        }

        return items
    }
}
