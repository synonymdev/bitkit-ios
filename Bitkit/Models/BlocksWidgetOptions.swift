import Foundation

/// Options for configuring the in-app and home-screen Bitcoin Blocks widgets (shared via App Group).
struct BlocksWidgetOptions: Codable, Equatable {
    var height: Bool = true
    var time: Bool = true
    var date: Bool = true
    var transactionCount: Bool = true
    var size: Bool = false
    var fees: Bool = false

    init(
        height: Bool = true,
        time: Bool = true,
        date: Bool = true,
        transactionCount: Bool = true,
        size: Bool = false,
        fees: Bool = false
    ) {
        self.height = height
        self.time = time
        self.date = date
        self.transactionCount = transactionCount
        self.size = size
        self.fees = fees
        limitEnabledFields()
    }

    private enum CodingKeys: String, CodingKey {
        case height
        case time
        case date
        case transactionCount
        case size
        case fees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        height = try container.decodeIfPresent(Bool.self, forKey: .height) ?? true
        time = try container.decodeIfPresent(Bool.self, forKey: .time) ?? true
        date = try container.decodeIfPresent(Bool.self, forKey: .date) ?? true
        transactionCount = try container.decodeIfPresent(Bool.self, forKey: .transactionCount) ?? true
        size = try container.decodeIfPresent(Bool.self, forKey: .size) ?? false
        fees = try container.decodeIfPresent(Bool.self, forKey: .fees) ?? false
        limitEnabledFields()
    }

    private mutating func limitEnabledFields() {
        let fields: [WritableKeyPath<BlocksWidgetOptions, Bool>] = [
            \.height,
            \.time,
            \.date,
            \.transactionCount,
            \.size,
            \.fees,
        ]

        var enabledCount = 0
        for field in fields where self[keyPath: field] {
            if enabledCount < 4 {
                enabledCount += 1
            } else {
                self[keyPath: field] = false
            }
        }
    }
}
