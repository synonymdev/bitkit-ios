@testable import Bitkit
import Foundation
import XCTest

final class ClipboardPromptHistoryTests: XCTestCase {
    func testUnchangedClipboardIsNotReofferedAfterRelaunch() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(history.shouldInspect(changeCount: 12))
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1example"))
        XCTAssertFalse(history.shouldInspect(changeCount: 12))

        let relaunchedHistory = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(relaunchedHistory.shouldInspect(changeCount: 12))
        XCTAssertFalse(relaunchedHistory.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1example"))
        XCTAssertFalse(relaunchedHistory.shouldInspect(changeCount: 12))
    }

    func testNewContentAtSameChangeCountIsOfferedAfterRelaunch() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1old"))

        let relaunchedHistory = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(relaunchedHistory.shouldInspect(changeCount: 12))
        XCTAssertTrue(relaunchedHistory.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1new"))
        XCTAssertFalse(relaunchedHistory.shouldInspect(changeCount: 12))
    }

    func testSameChangeCountIsSkippedWithinSameLaunch() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let launchID = UUID()
        let history = ClipboardPromptHistory(defaults: defaults, launchID: launchID)
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1example"))

        let recreatedHistory = ClipboardPromptHistory(defaults: defaults, launchID: launchID)
        XCTAssertFalse(recreatedHistory.shouldInspect(changeCount: 12))
    }

    func testCopyingTheSameValueAgainIsFreshIntent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = ClipboardPromptHistory(defaults: defaults)
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1example"))
        XCTAssertTrue(history.shouldInspect(changeCount: 13))
        XCTAssertTrue(history.recordInspection(changeCount: 13, supportedValue: "bitcoin:bc1example"))
        XCTAssertFalse(history.shouldInspect(changeCount: 13))
    }

    func testResetChangeCountDoesNotReofferUnchangedContent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1example"))

        let rebootedHistory = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(rebootedHistory.shouldInspect(changeCount: 0))
        XCTAssertFalse(rebootedHistory.recordInspection(changeCount: 0, supportedValue: "bitcoin:bc1example"))
        XCTAssertFalse(rebootedHistory.shouldInspect(changeCount: 0))
        XCTAssertTrue(rebootedHistory.recordInspection(changeCount: 1, supportedValue: "bitcoin:bc1example"))
    }

    func testNewContentIsOfferedAfterChangeCountReset() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: "bitcoin:bc1old"))

        let rebootedHistory = ClipboardPromptHistory(defaults: defaults, launchID: UUID())
        XCTAssertTrue(rebootedHistory.recordInspection(changeCount: 0, supportedValue: "bitcoin:bc1new"))
    }

    func testSavedObservationWithoutLaunchIDIsReinspected() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data(#"{"changeCount":12,"digest":null}"#.utf8), forKey: "lastInspectedClipboard")
        let history = ClipboardPromptHistory(defaults: defaults)
        XCTAssertTrue(history.shouldInspect(changeCount: 12))
    }

    func testUnsupportedContentIsMarkedSeen() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = ClipboardPromptHistory(defaults: defaults)
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: nil))
        XCTAssertFalse(history.shouldInspect(changeCount: 12))
    }

    func testRawSupportedContentIsNotPersisted() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let value = "bitcoin:bc1example"
        let history = ClipboardPromptHistory(defaults: defaults)
        XCTAssertTrue(history.recordInspection(changeCount: 12, supportedValue: value))

        let storedData = try XCTUnwrap(defaults.data(forKey: "lastInspectedClipboard"))
        XCTAssertFalse(String(decoding: storedData, as: UTF8.self).contains(value))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ClipboardPromptHistoryTests.\(UUID().uuidString)"
        return try (XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
