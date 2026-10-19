import CryptoKit
import ImageIO
import Paykit
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
        } catch PubkyImageError.recentlyFailed {
            hasFailed = true
        } catch {
            Logger.error("Failed to load pubky image: \(error)", context: "PubkyImage")
            hasFailed = true
        }
    }

    /// All heavy work (disk cache, network/FFI) runs off the main actor. A URI whose fetch failed recently fails at once
    /// without the network, while a disk cache hit still wins.
    nonisolated static func loadImageOffMain(
        uri: String,
        cache: PubkyImageCache = .shared,
        fetchFile: @escaping @Sendable (_ uri: String, _ maxBytes: UInt64) async throws -> Data = {
            try await PubkyService.fetchFile(uri: $0, maxBytes: $1)
        }
    ) async throws -> UIImage {
        let cacheGeneration = cache.generation
        if let cached = await cache.image(for: uri, generation: cacheGeneration) {
            return cached
        }
        guard !cache.hasRecentFailure(for: uri) else {
            throw PubkyImageError.recentlyFailed
        }

        do {
            let data = try await fetchFile(uri, PubkyImagePolicy.maxDownloadBytes)
            let blobData = try await resolveImageData(data, originalUri: uri, fetchFile: fetchFile)

            let image = try PubkyImageDecoder.image(from: blobData)

            cache.store(image, data: blobData, for: uri, generation: cacheGeneration)
            return image
        } catch {
            if !Task.isCancelled {
                cache.rememberFailure(error, for: uri, generation: cacheGeneration)
            }
            throw error
        }
    }

    private nonisolated static func resolveImageData(
        _ data: Data,
        originalUri: String,
        fetchFile: @Sendable (_ uri: String, _ maxBytes: UInt64) async throws -> Data
    ) async throws -> Data {
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
        return try await fetchFile(src, PubkyImagePolicy.maxDownloadBytes)
    }
}

enum PubkyImagePolicy {
    static let maxDownloadBytes: UInt64 = 1024 * 1024
    static let maxPixelSize = 512
    static let memoryCacheBytes = 32 * 1024 * 1024
    static let diskCacheBytes = 32 * 1024 * 1024
    /// How long an image whose fetch failed for a reason that can pass, such as a network error, is not fetched again.
    static let transientFailureTTL: TimeInterval = 60
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
    case recentlyFailed

    var errorDescription: String? {
        switch self {
        case let .decodingFailed(bytes):
            return "Could not decode image blob (\(bytes) bytes)"
        case let .fileTooLarge(bytes):
            return "Image blob exceeds the byte limit (\(bytes) bytes)"
        case .crossUserRedirect:
            return "Image descriptor references a different user's namespace"
        case .recentlyFailed:
            return "Image fetch failed recently"
        }
    }
}

/// Two-tier cache (memory + disk) so profile images persist across app launches
/// and multiple PubkyImage views with the same URI don't re-fetch.
///
/// It also remembers failed fetches by URI, so an image that cannot load is not fetched again each time it is shown. A
/// missing file and a file over `PubkyImagePolicy.maxDownloadBytes` are remembered until `clear()`, which sign-out and
/// a switch to another identity run, and any other failure for `PubkyImagePolicy.transientFailureTTL`. For a file
/// descriptor, a failed blob fetch counts as a failure of the descriptor URI.
final class PubkyImageCache: @unchecked Sendable {
    static let shared = PubkyImageCache()

    private struct MemoryEntry {
        let image: UIImage
        let cost: Int
        var lastAccess: UInt64
    }

    private struct Failure {
        let expiresAt: Date?
    }

    private var memoryCache: [String: MemoryEntry] = [:]
    /// Guarded by `memoryLock`, like the memory cache, so `clear()` empties both at once.
    private var failures: [String: Failure] = [:]
    private var memoryCost = 0
    private var accessSequence: UInt64 = 0
    private var clearGeneration: UInt64 = 0
    private let memoryLock = NSLock()
    private let diskQueue = DispatchQueue(label: "pubky-image-cache-disk", qos: .utility)
    private let diskDirectory: URL
    private let maxFileBytes: Int
    private let maxMemoryBytes: Int
    private let maxDiskBytes: Int
    private let currentDate: @Sendable () -> Date

    init(
        diskDirectory: URL? = nil,
        maxFileBytes: Int = Int(PubkyImagePolicy.maxDownloadBytes),
        memoryCostLimit: Int = PubkyImagePolicy.memoryCacheBytes,
        diskByteLimit: Int = PubkyImagePolicy.diskCacheBytes,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDirectory = diskDirectory ?? caches.appendingPathComponent("pubky-images", isDirectory: true)
        self.maxFileBytes = maxFileBytes
        maxMemoryBytes = memoryCostLimit
        maxDiskBytes = diskByteLimit
        self.currentDate = currentDate
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
    /// A disk hit is promoted to memory only while `generation` is still current, as with `store`.
    func image(for uri: String, generation: UInt64) async -> UIImage? {
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
                storeInMemory(diskImage, for: uri, generation: generation)
                continuation.resume(returning: diskImage)
            }
        }
    }

    /// Bumped by `clear()`. Capture it before fetching and pass it to `store`, so a fetch that finishes after a sign-out
    /// or wipe cannot put the previous identity's image back.
    var generation: UInt64 {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return clearGeneration
    }

    /// Drops the write, in memory and on disk, when `clear()` ran after `generation` was captured.
    func store(_ image: UIImage, data: Data, for uri: String, generation: UInt64) {
        guard data.count <= maxFileBytes else { return }

        storeInMemory(image, for: uri, generation: generation)

        diskQueue.async { [self] in
            guard generation == self.generation else { return }
            let path = diskPath(for: uri)
            try? data.write(to: path, options: .atomic)
            trimDiskCache()
        }
    }

    /// True while a failed fetch of `uri` is remembered, so the image shows its failed state without fetching again.
    func hasRecentFailure(for uri: String) -> Bool {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        guard let failure = failures[uri] else { return false }
        if let expiresAt = failure.expiresAt, currentDate() >= expiresAt {
            failures[uri] = nil
            return false
        }
        return true
    }

    /// Remembers that a fetch of `uri` failed with `error`. Like `store`, it is dropped when `clear()` ran after
    /// `generation` was captured, and a cancelled fetch is not remembered.
    func rememberFailure(_ error: Error, for uri: String, generation: UInt64) {
        guard !(error is CancellationError) else { return }
        let expiresAt = Self.isPermanentFailure(error) ? nil : currentDate().addingTimeInterval(PubkyImagePolicy.transientFailureTTL)

        memoryLock.lock()
        defer { memoryLock.unlock() }
        guard generation == clearGeneration else { return }
        failures[uri] = Failure(expiresAt: expiresAt)
    }

    /// A missing file, or one over the download limit, stays that way until the profile points at another image.
    private static func isPermanentFailure(_ error: Error) -> Bool {
        if case .profileNotFound? = error as? PubkyServiceError {
            return true
        }
        if case .fileTooLarge? = error as? PubkyImageError {
            return true
        }
        switch error as? PaykitError {
        case .NotFound?:
            return true
        case let .Protocol(_, context)?:
            return context.contains("exceeds maximum size")
        default:
            return false
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
        clearGeneration &+= 1
        memoryCache.removeAll()
        failures.removeAll()
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

    private func storeInMemory(_ image: UIImage, for uri: String, generation: UInt64) {
        let cost = Self.memoryCost(of: image)

        memoryLock.lock()
        defer { memoryLock.unlock() }

        guard generation == clearGeneration else { return }
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
