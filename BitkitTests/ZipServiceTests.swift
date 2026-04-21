@testable import Bitkit
import Foundation
import XCTest

final class ZipServiceTests: XCTestCase {
    private var testRootDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRootDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("ZipServiceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRootDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRootDirectoryURL {
            try? FileManager.default.removeItem(at: testRootDirectoryURL)
        }
        testRootDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testCreateZipFromFilesToZipHandlesDuplicateAndPathLikeNames() throws {
        let sourceA = testRootDirectoryURL.appendingPathComponent("sourceA.log")
        let sourceB = testRootDirectoryURL.appendingPathComponent("sourceB.log")
        try "alpha".data(using: .utf8)?.write(to: sourceA)
        try "beta".data(using: .utf8)?.write(to: sourceB)

        let filesToZip: [FileToZip] = [
            .renamedFile(sourceA, toFilename: "logs/app.log"),
            .renamedFile(sourceB, toFilename: "logs/app.log"),
        ]

        let zipService = ZipService()
        let zipData = try zipService.getZipData(zipFilename: "sanitized", filesToZip: filesToZip)

        XCTAssertFalse(zipData.isEmpty)
        XCTAssertEqual(String(data: zipData.prefix(2), encoding: .ascii), "PK")
    }

    func testCreateZipThrowsForInvalidFilename() throws {
        let zipService = ZipService()
        let filesToZip: [FileToZip] = [.data(Data([0x01]), filename: " / ")]

        XCTAssertThrowsError(try zipService.getZipData(zipFilename: "invalid", filesToZip: filesToZip)) { error in
            guard case CreateZipError.invalidFilename = error else {
                return XCTFail("Expected invalidFilename error, got \(error)")
            }
        }
    }

    func testCreateZipOverwritesExistingFileByDefault() throws {
        let sourceDirectory = testRootDirectoryURL.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("sample.log")
        try "sample".data(using: .utf8)?.write(to: sourceFile)

        let zipFinalURL = testRootDirectoryURL.appendingPathComponent("output.zip")
        try Data("old-content".utf8).write(to: zipFinalURL)

        let zipService = ZipService()
        let outputURL = try zipService.createZip(zipFinalURL: zipFinalURL, fromDirectory: sourceDirectory)
        let zipData = try Data(contentsOf: outputURL)

        XCTAssertEqual(outputURL, zipFinalURL)
        XCTAssertFalse(zipData.isEmpty)
        XCTAssertEqual(String(data: zipData.prefix(2), encoding: .ascii), "PK")
    }
}
