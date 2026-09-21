import Foundation
import XCTest

/// Helpers that keep a test suite off the host app's own state.
///
/// `BitkitTests` is hosted in the Bitkit app (`TEST_HOST` in the project settings), so
/// `UserDefaults.standard` *is* the app's preferences and anything a test writes there lands in the
/// developer's wallet. Issue #733 is what that looks like in practice: mock transfer records left
/// behind by a test run pinned a permanent "TRANSFER IN PROGRESS" banner on the real wallet.
///
/// Reach for these in order of preference:
/// 1. `makeIsolatedDefaults()` when the code under test accepts injected defaults — nothing touches
///    the app's domain at all.
/// 2. `snapshotAppDefaults(_:)` when it does not, so the keys are put back afterwards.
/// 3. `guardAppDefaults(_:)` on suites that should write nothing, to keep it that way.
extension XCTestCase {
    /// A `UserDefaults` suite unique to this test, emptied before it runs and removed afterwards.
    func makeIsolatedDefaults(_ label: String = #function, file: StaticString = #filePath, line: UInt = #line) throws -> UserDefaults {
        let suiteName = "\(type(of: self)).\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), "Could not open suite \(suiteName)", file: file, line: line)
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// Restores `keys` in `UserDefaults.standard` when the test ends, removing any that are absent
    /// now. Use when the code under test has no seam for injected defaults.
    func snapshotAppDefaults(_ keys: String...) {
        let defaults = UserDefaults.standard
        let snapshot = keys.map { (key: $0, value: defaults.object(forKey: $0)) }
        addTeardownBlock {
            for entry in snapshot {
                if let value = entry.value {
                    defaults.set(value, forKey: entry.key)
                } else {
                    defaults.removeObject(forKey: entry.key)
                }
            }
        }
    }

    /// Fails the test if it leaves any of `keys` in `UserDefaults.standard` changed. The regression
    /// guard for #733: a suite that should be writing to an isolated suite goes red here instead of
    /// silently corrupting the wallet on the simulator.
    func guardAppDefaults(_ keys: String..., file: StaticString = #filePath, line: UInt = #line) {
        let defaults = UserDefaults.standard
        let before = keys.map { (key: $0, value: defaults.object(forKey: $0) as? NSObject) }
        addTeardownBlock {
            for entry in before where defaults.object(forKey: entry.key) as? NSObject != entry.value {
                // Deliberately not interpolating the values: these keys hold large encoded blobs, and
                // dumping both of them buries the one line that says what to do about it.
                XCTFail(
                    """
                    '\(entry.key)' in UserDefaults.standard was modified by this test, which writes to the host app's \
                    own preferences. Inject an isolated suite with makeIsolatedDefaults(), or snapshot the key with \
                    snapshotAppDefaults(_:) if the code under test has no seam for it.
                    """,
                    file: file,
                    line: line
                )
            }
        }
    }
}
