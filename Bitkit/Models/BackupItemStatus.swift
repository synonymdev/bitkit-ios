import Foundation

struct BackupItemStatus: Codable, Equatable {
    var synced: UInt64 = 0
    var required: UInt64 = 0
    var running: Bool = false

    var isRequired: Bool {
        synced < required
    }
}
