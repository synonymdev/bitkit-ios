import XCTest

@MainActor
extension XCTestCase {
    /// Waits until `condition` holds, failing the test at the caller's line if it does not within `timeout`, so a test cannot
    /// go on to pass without the state it waited for. The condition may await, to read state an actor or a fake holds.
    func eventually(
        _ description: String = "the condition holds",
        timeout: Duration = .seconds(5),
        pollEvery interval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting until \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: interval)
        }
    }
}
