import Foundation

struct CreateCjitOptions_OLD: Codable {
    /**
     * What created this order. Example: 'bitkit', 'widget'
     */
    var source: String?
    /**
     * User entered discount code.
     */
    var discountCode: String?
}
