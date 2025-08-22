import Foundation

/// Tries to execute a throwing async operation N times, with a delay between each attempt.
/// - Parameters:
///   - toTry: The async operation to try to execute
///   - times: The maximum number of attempts (must be greater than 0)
///   - interval: The interval of time between each attempt in seconds
/// - Returns: The result of the successful operation
/// - Throws: The error from the last failed attempt
func tryNTimes<T>(
    toTry: () async throws -> T,
    times: Int = 5,
    interval: UInt64 = 5
) async throws -> T {
    guard times > 0 else {
        throw NSError(
            domain: "RetryHelper",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Bad argument: 'times' must be greater than 0, but \(times) was received."]
        )
    }

    var attemptCount = 0

    while true {
        do {
            return try await toTry()
        } catch {
            attemptCount += 1

            if attemptCount >= times {
                throw error
            }

            // Wait before next attempt
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
        }
    }
}
