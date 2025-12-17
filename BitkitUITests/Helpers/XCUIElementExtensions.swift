//
//  XCUIElementExtensions.swift
//  BitkitUITests
//
//  Extensions for XCUIElement to support additional test operations
//

import XCTest

extension XCUIElement {
    /// Wait for element to disappear (non-existence)
    func waitForNonexistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
    
    /// Tap element if it exists
    func tapIfExists() -> Bool {
        guard exists else { return false }
        tap()
        return true
    }
    
    /// Wait for element and tap if found
    func waitAndTap(timeout: TimeInterval = 5) -> Bool {
        guard waitForExistence(timeout: timeout) else { return false }
        tap()
        return true
    }
}

