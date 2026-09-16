import CryptoKit
import ImageIO
import SwiftUI

/// Loads and displays an image from a `pubky://` URI using Paykit's Pubky file fetch.
/// Handles the Pubky file indirection: the URI may point to a JSON metadata object
/// with a `src` field containing the actual blob URI.
struct PubkyImage: View {
    let uri: String
    let size: CGFloat
    var cornerRadius: CGFloat?

    @State private var uiImage: UIImage?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if hasFailed {
                placeholder
            } else {
                ProgressView()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size / 2))
        .accessibilityLabel(Text("Profile photo"))
        .task(id: uri) {
            await loadImage()
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.gray5)
            .overlay {
                Image("user-square")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.white32)
                    .frame(width: size / 2, height: size / 2)
            }
    }

    private func loadImage() async {
        hasFailed = false

        if let memoryHit = PubkyImageCache.shared.memoryImage(for: uri) {
            uiImage = memoryHit
            return
        }

        uiImage = nil

        do {
            let image = try await Task.detached {
                try await Self.loadImageOffMain(uri: uri)
            }.value
            uiImage = image
        } catch {
            Logger.error("Failed to load pubky image: \(error)", context: "PubkyImage")
            hasFailed = true
        }
    }

    /// All heavy work (disk cache, network/FFI) runs off the main actor.
    private nonisolated static func loadImageOffMain(uri: String) async throws -> UIImage {
        if let cached = await PubkyImageCache.shared.image(for: uri) {
            return cached
        }

        let data = try await PubkyService.fetchFile(uri: uri, maxBytes: PubkyImagePolicy.maxDownloadBytes)
        let blobData = try await resolveImageData(data, originalUri: uri)

        let image = try PubkyImageDecoder.image(from: blobData)

        PubkyImageCache.shared.store(image, data: blobData, for: uri)
        return image
    }

    private nonisolated static func resolveImageData(_ data: Data, originalUri: String) async throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let src = json["src"] as? String,
              src.hasPrefix("pubky://")
        else {
            return data
        }

        let originalPubkey = originalUri.dropFirst("pubky://".count).prefix(while: { $0 != "/" })
        let srcPubkey = src.dropFirst("pubky://".count).prefix(while: { $0 != "/" })
        guard !originalPubkey.isEmpty, originalPubkey == srcPubkey else {
            Logger.warn("Rejected cross-user src redirect: \(src)", context: "PubkyImage")
            throw PubkyImageError.crossUserRedirect
        }

        Logger.debug("File descriptor found, fetching blob from: \(src)", context: "PubkyImage")
        return try await PubkyService.fetchFile(uri: src, maxBytes: PubkyImagePolicy.maxDownloadBytes)
    }
}

enum PubkyImagePolicy {
    static let maxDownloadBytes: UInt64 = 1024 * 1024
    static let maxPixelSize = 512
    static let memoryCacheBytes = 32 * 1024 * 1024
    static let diskCacheBytes = 32 * 1024 * 1024
}

enum PubkyImageDecoder {
    static func image(from data: Data, maxPixelSize: Int = PubkyImagePolicy.maxPixelSize) throws -> UIImage {
        guard UInt64(data.count) <= PubkyImagePolicy.maxDownloadBytes else {
            throw PubkyImageError.fileTooLarge(data.count)
        }
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else {
            throw PubkyImageError.decodingFailed(data.count)
        }
        return UIImage(cgImage: thumbnail)
    }
}

private enum PubkyImageError: LocalizedError {
    case decodingFailed(Int)
    case fileTooLarge(Int)
    case crossUserRedirect

    var errorDescription: String? {
        switch self {
        case let .decodingFailed(bytes):
            return "Could not decode image blob (\(bytes) bytes)"
        case let .fileTooLarge(bytes):
            return "Image blob exceeds the byte limit (\(bytes) bytes)"
        case .crossUserRedirect:
            return "Image descriptor references a different user's namespace"
        }
    }
}

/// Two-tier cache (memory + disk) so profile images persist across app launches
/// and multiple PubkyImage views with the same URI don't re-fetch.
final class PubkyImageCache: @unchecked Sendable {
    static let shared = PubkyImageCache()

    private struct MemoryEntry {
        let image: UIImage
        let cost: Int
        var lastAccess: UInt64
    }

    private var memoryCache: [String: MemoryEntry] = [:]
    private var memoryCost = 0
    private var accessSequence: UInt64 = 0
    private let memoryLock = NSLock()
    private let diskQueue = DispatchQueue(label: "pubky-image-cache-disk", qos: .utility)
    private let diskDirectory: URL
    private let maxFileBytes: Int
    private let maxMemoryBytes: Int
    private let maxDiskBytes: Int

    init(
        diskDirectory: URL? = nil,
        maxFileBytes: Int = Int(PubkyImagePolicy.maxDownloadBytes),
        memoryCostLimit: Int = PubkyImagePolicy.memoryCacheBytes,
        diskByteLimit: Int = PubkyImagePolicy.diskCacheBytes
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDirectory = diskDirectory ?? caches.appendingPathComponent("pubky-images", isDirectory: true)
        self.maxFileBytes = maxFileBytes
        maxMemoryBytes = memoryCostLimit
        maxDiskBytes = diskByteLimit
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        diskQueue.async { [self] in
            trimDiskCache()
        }
    }

    /// Fast memory-only check — never blocks behind disk I/O, safe from the main thread.
    func memoryImage(for uri: String) -> UIImage? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        guard var entry = memoryCache[uri] else { return nil }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        memoryCache[uri] = entry
        return entry.image
    }

    /// Full lookup (memory + disk). Disk I/O runs on a dedicated queue to avoid blocking cooperative threads.
    func image(for uri: String) async -> UIImage? {
        if let memoryHit = memoryImage(for: uri) {
            return memoryHit
        }

        return await withCheckedContinuation { continuation in
            diskQueue.async { [self] in
                let path = diskPath(for: uri)
                guard let fileSize = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      fileSize <= maxFileBytes
                else {
                    try? FileManager.default.removeItem(at: path)
                    continuation.resume(returning: nil)
                    return
                }

                guard let diskData = try? Data(contentsOf: path),
                      let diskImage = try? PubkyImageDecoder.image(from: diskData)
                else {
                    try? FileManager.default.removeItem(at: path)
                    continuation.resume(returning: nil)
                    return
                }

                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
                storeInMemory(diskImage, for: uri)
                continuation.resume(returning: diskImage)
            }
        }
    }

    func store(_ image: UIImage, data: Data, for uri: String) {
        guard data.count <= maxFileBytes else { return }

        storeInMemory(image, for: uri)

        diskQueue.async { [self] in
            let path = diskPath(for: uri)
            try? data.write(to: path, options: .atomic)
            trimDiskCache()
        }
    }

    func clear() async {
        clearMemoryCache()

        await withCheckedContinuation { continuation in
            diskQueue.async { [diskDirectory] in
                try? FileManager.default.removeItem(at: diskDirectory)
                try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
                continuation.resume()
            }
        }
    }

    private func clearMemoryCache() {
        memoryLock.lock()
        memoryCache.removeAll()
        memoryCost = 0
        memoryLock.unlock()
    }

    private static func diskHash(for uri: String) -> String {
        let data = Data(uri.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func diskPath(for uri: String) -> URL {
        diskDirectory.appendingPathComponent(Self.diskHash(for: uri))
    }

    private static func memoryCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private func storeInMemory(_ image: UIImage, for uri: String) {
        let cost = Self.memoryCost(of: image)

        memoryLock.lock()
        defer { memoryLock.unlock() }

        if let replaced = memoryCache.removeValue(forKey: uri) {
            memoryCost -= replaced.cost
        }
        guard cost <= maxMemoryBytes else { return }

        accessSequence &+= 1
        memoryCache[uri] = MemoryEntry(image: image, cost: cost, lastAccess: accessSequence)
        memoryCost += cost

        while memoryCost > maxMemoryBytes,
              let leastRecentlyUsed = memoryCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })
        {
            memoryCache.removeValue(forKey: leastRecentlyUsed.key)
            memoryCost -= leastRecentlyUsed.value.cost
        }
    }

    private func trimDiskCache() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let entries = urls.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, fileSize)
        }
        var totalBytes = entries.reduce(0) { $0 + $1.size }

        for entry in entries.sorted(by: { $0.date < $1.date }) where totalBytes > maxDiskBytes {
            do {
                try FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.size
            } catch {}
        }
    }
}
