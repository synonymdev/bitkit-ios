import BitkitCore
import Foundation

struct UsdtPreparedQuote {
    let quote: UsdtQuote
    let amount: String
    let sender: String

    func matches(recipient: String, amount: String, destination: UsdtDestination, sender: String, now: Date = Date()) -> Bool {
        !sender.isEmpty && self.sender == sender && self.amount == amount && quote.recipient == recipient && quote.destination == destination
            && Double(quote.expiresAt) > now.timeIntervalSince1970 + 5
    }
}

extension UsdtQuote {
    var totalCost: UInt64 {
        let deductedFee = amount - min(amount, receivedAmount)
        let (cost, overflow) = maximumFee.addingReportingOverflow(deductedFee)
        return overflow ? UInt64.max : cost
    }
}
