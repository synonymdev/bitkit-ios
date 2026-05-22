@testable import Bitkit
import XCTest

@MainActor
final class WidgetsViewModelDedupTests: XCTestCase {
    func testDedupedByType_RemovesDuplicateWeatherEntries() {
        let input: [SavedWidget] = [
            SavedWidget(type: .suggestions),
            SavedWidget(type: .weather),
            SavedWidget(type: .price),
            SavedWidget(type: .weather),
        ]
        let result = WidgetsViewModel.dedupedByType(input)
        XCTAssertEqual(result.map(\.type), [.suggestions, .weather, .price])
    }

    func testDedupedByType_PrefersEntryWithOptionsData() {
        let optionsData = Data([0xAB, 0xCD])
        let input: [SavedWidget] = [
            SavedWidget(type: .weather, optionsData: nil),
            SavedWidget(type: .weather, optionsData: optionsData),
        ]
        let result = WidgetsViewModel.dedupedByType(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .weather)
        XCTAssertEqual(result.first?.optionsData, optionsData)
    }

    func testDedupedByType_NoChangeWhenAlreadyUnique() {
        let input: [SavedWidget] = [
            SavedWidget(type: .suggestions),
            SavedWidget(type: .price),
            SavedWidget(type: .blocks),
            SavedWidget(type: .weather, optionsData: Data([0x01])),
        ]
        let result = WidgetsViewModel.dedupedByType(input)
        XCTAssertEqual(result.map(\.type), input.map(\.type))
        XCTAssertEqual(result.last?.optionsData, Data([0x01]))
    }

    func testDedupedByType_PrefersFirstNonNilOptionsAcrossMultipleDups() {
        let first = Data([0x01])
        let second = Data([0x02])
        let input: [SavedWidget] = [
            SavedWidget(type: .weather, optionsData: nil),
            SavedWidget(type: .weather, optionsData: first),
            SavedWidget(type: .weather, optionsData: second),
        ]
        let result = WidgetsViewModel.dedupedByType(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.optionsData, first)
    }

    func testDedupedByType_EmptyInputReturnsEmpty() {
        XCTAssertTrue(WidgetsViewModel.dedupedByType([]).isEmpty)
    }
}
