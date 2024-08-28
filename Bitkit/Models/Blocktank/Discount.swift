import Foundation

struct Discount: Codable {
    var code: String
    var absoluteSat: Int
    var relative: Int
    var overallSat: Int
}