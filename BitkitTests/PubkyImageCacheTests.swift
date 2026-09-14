@testable import Bitkit
import CryptoKit
import UIKit
import XCTest

final class PubkyImageCacheTests: XCTestCase {
    func testClearRemovesCachedImageFromMemoryAndDisk() async throws {
        let cache = PubkyImageCache.shared
        let uri = "pubky://test-user/pub/bitkit.to/blobs/avatar.jpg"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let imageData = try XCTUnwrap(image.pngData())
        let diskPath = pubkyImageDiskPath(for: uri)

        await cache.clear()
        cache.store(image, data: imageData, for: uri)

        XCTAssertNotNil(cache.memoryImage(for: uri))

        let fileStored = await waitForFile(at: diskPath)
        XCTAssertTrue(fileStored)

        await cache.clear()

        XCTAssertNil(cache.memoryImage(for: uri))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskPath.path))
        let diskImage = await cache.image(for: uri)
        XCTAssertNil(diskImage)
    }

    func testDecoderDownsamplesLargeImagesBeforeCaching() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let sourceData = try XCTUnwrap(sourceImage.pngData())

        let decodedImage = try PubkyImageDecoder.image(from: sourceData, maxPixelSize: 512)
        let decoded = try XCTUnwrap(decodedImage.cgImage)

        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 512)
    }

    func testDecoderRejectsDataOverDownloadLimit() {
        let data = Data(count: Int(PubkyImagePolicy.maxDownloadBytes) + 1)

        XCTAssertThrowsError(try PubkyImageDecoder.image(from: data)) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Image blob exceeds the byte limit (\(data.count) bytes)")
        }
    }

    func testDiskCacheRemovesLeastRecentlyUsedFilesOverLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURI = "pubky://test-user/pub/bitkit.to/blobs/first.jpg"
        let secondURI = "pubky://test-user/pub/bitkit.to/blobs/second.jpg"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let imageData = try XCTUnwrap(image.pngData())
        let cache = PubkyImageCache(
            diskDirectory: directory,
            maxFileBytes: imageData.count,
            memoryCostLimit: 1024,
            diskByteLimit: imageData.count
        )
        let firstPath = pubkyImageDiskPath(for: firstURI, directory: directory)
        let secondPath = pubkyImageDiskPath(for: secondURI, directory: directory)

        cache.store(image, data: imageData, for: firstURI)
        let storedFirstFile = await waitForFile(at: firstPath)
        XCTAssertTrue(storedFirstFile)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: firstPath.path)
        cache.store(image, data: imageData, for: secondURI)

        let storedSecondFile = await waitForFile(at: secondPath)
        let removedFirstFile = await waitForMissingFile(at: firstPath)
        XCTAssertTrue(storedSecondFile)
        XCTAssertTrue(removedFirstFile)
    }

    func testMemoryCacheEnforcesCostLimitAndAccountsForReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURI = "pubky://test-user/pub/bitkit.to/blobs/first-memory.jpg"
        let secondURI = "pubky://test-user/pub/bitkit.to/blobs/second-memory.jpg"
        let firstImage = image(color: .red)
        let replacementImage = image(color: .blue)
        let imageData = try XCTUnwrap(firstImage.pngData())
        let decodedImage = try XCTUnwrap(firstImage.cgImage)
        let decodedCost = decodedImage.bytesPerRow * decodedImage.height
        let cache = PubkyImageCache(
            diskDirectory: directory,
            maxFileBytes: imageData.count,
            memoryCostLimit: decodedCost,
            diskByteLimit: imageData.count * 3
        )

        cache.store(firstImage, data: imageData, for: firstURI)
        cache.store(replacementImage, data: imageData, for: firstURI)
        XCTAssertEqual(cache.memoryImage(for: firstURI)?.pngData(), replacementImage.pngData())

        cache.store(firstImage, data: imageData, for: secondURI)
        XCTAssertNil(cache.memoryImage(for: firstURI))
        XCTAssertNotNil(cache.memoryImage(for: secondURI))
    }

    func testDiskCacheTrimsExistingFilesAtInitialization() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURI = "pubky://test-user/pub/bitkit.to/blobs/first-existing.jpg"
        let secondURI = "pubky://test-user/pub/bitkit.to/blobs/second-existing.jpg"
        let imageData = try XCTUnwrap(image(color: .red).pngData())
        let firstPath = pubkyImageDiskPath(for: firstURI, directory: directory)
        let secondPath = pubkyImageDiskPath(for: secondURI, directory: directory)
        try imageData.write(to: firstPath)
        try imageData.write(to: secondPath)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: firstPath.path)

        let cache = PubkyImageCache(
            diskDirectory: directory,
            maxFileBytes: imageData.count,
            memoryCostLimit: 1024,
            diskByteLimit: imageData.count
        )

        let removedFirstFile = await waitForMissingFile(at: firstPath)
        let remainingImage = await cache.image(for: secondURI)
        XCTAssertTrue(removedFirstFile)
        XCTAssertNotNil(remainingImage)
    }

    func testDiskCacheRejectsFilesOverPerFileLimitBeforeDecoding() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let uri = "pubky://test-user/pub/bitkit.to/blobs/oversized.jpg"
        let path = pubkyImageDiskPath(for: uri, directory: directory)
        let cache = PubkyImageCache(diskDirectory: directory, maxFileBytes: 3, memoryCostLimit: 1024, diskByteLimit: 1024)
        try Data([0, 1, 2, 3]).write(to: path)

        let image = await cache.image(for: uri)
        XCTAssertNil(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    private func pubkyImageDiskPath(for uri: String, directory: URL? = nil) -> URL {
        let caches = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let hash = SHA256.hash(data: Data(uri.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let cacheDirectory = directory == nil ? caches.appendingPathComponent("pubky-images", isDirectory: true) : caches
        return cacheDirectory.appendingPathComponent(hash)
    }

    private func waitForFile(at path: URL, attempts: Int = 10) async -> Bool {
        for _ in 0 ..< attempts {
            if FileManager.default.fileExists(atPath: path.path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func waitForMissingFile(at path: URL, attempts: Int = 10) async -> Bool {
        for _ in 0 ..< attempts {
            if !FileManager.default.fileExists(atPath: path.path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
