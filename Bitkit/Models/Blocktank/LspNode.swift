import Foundation

struct LspNode: Codable {
    var alias: String
    var pubkey: String
    var connectionStrings: [String]
    var readonly: Bool?
}