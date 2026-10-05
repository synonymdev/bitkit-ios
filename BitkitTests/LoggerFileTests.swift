@testable import Bitkit
import XCTest

final class LoggerFileTests: XCTestCase {
    func testLoggingResumesAfterLogDirectoryRemoval() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("LoggerFileTests-\(UUID().uuidString)")
        let logDirectory = temporaryDirectory.appendingPathComponent("logs")
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let logFilePath = logDirectory.appendingPathComponent("session.log").path

        Bitkit.Logger.queue.sync {
            Bitkit.Logger.writeToFile("before wipe", logFilePath: logFilePath)
        }
        XCTAssertTrue(try String(contentsOfFile: logFilePath, encoding: .utf8).contains("before wipe"))

        try fileManager.removeItem(at: logDirectory)

        Bitkit.Logger.queue.sync {
            Bitkit.Logger.writeToFile("after wipe", logFilePath: logFilePath)
        }
        let afterWipe = try String(contentsOfFile: logFilePath, encoding: .utf8)
        XCTAssertTrue(afterWipe.contains("after wipe"))
        XCTAssertFalse(afterWipe.contains("before wipe"))

        Bitkit.Logger.queue.sync {
            Bitkit.Logger.writeToFile("later message", logFilePath: logFilePath)
        }
        let laterContents = try String(contentsOfFile: logFilePath, encoding: .utf8)
        XCTAssertTrue(laterContents.contains("after wipe"))
        XCTAssertTrue(laterContents.contains("later message"))
    }
}
