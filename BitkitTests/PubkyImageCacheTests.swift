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

    private func pubkyImageDiskPath(for uri: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let hash = SHA256.hash(data: Data(uri.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("pubky-images", isDirectory: true).appendingPathComponent(hash)
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
}
