import Foundation

extension FixedWidthInteger {
    func saturatingAdd(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? Self.max : sum
    }

    func saturatingSub(_ other: Self) -> Self {
        let (difference, overflow) = subtractingReportingOverflow(other)
        guard overflow else { return difference }
        return other < 0 ? Self.max : Self.min
    }

    func saturatingMultiply(_ other: Self) -> Self {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        guard overflow else { return product }
        return (self < 0) != (other < 0) ? Self.min : Self.max
    }
}
