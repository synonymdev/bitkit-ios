import Foundation

extension FixedWidthInteger {
    func saturatingAdd(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Self.max : sum
    }

    func saturatingSub(_ other: Self) -> Self {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? Self.min : difference
    }
}
