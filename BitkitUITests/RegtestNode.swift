import XCTest

extension XCUIApplication {
    /// UI test builds run on regtest against staging Electrum. When the Bitcoin node can't start or
    /// sync there, skip instead of failing, so a staging outage doesn't block every PR.
    func skipIfBitcoinNodeUnavailable(waitingFor element: XCUIElement, timeout: TimeInterval) throws {
        let nodeError = otherElements["WalletRestoreError"]
        let nodeSyncing = otherElements["SendSync"]
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists || nodeError.exists },
            object: nil
        )
        _ = XCTWaiter.wait(for: [settled], timeout: timeout)
        if !element.exists, nodeError.exists || nodeSyncing.exists {
            throw XCTSkip("Requires the regtest Bitcoin node, which can't start or sync while staging Electrum is unavailable")
        }
    }
}
