import Foundation

extension FixedWidthInteger {
    func saturatingAdd(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Self.max : sum
    }
}
