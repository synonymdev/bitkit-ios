import CryptoKit
import SwiftUI

/// Loads and displays an image from a `pubky://` URI using BitkitCore's PKDNS resolver.
/// Handles the Pubky file indirection: the URI may point to a JSON metadata object
/// with a `src` field containing the actual blob URI.
struct PubkyImage: View {
    let uri: String
    let size: CGFloat

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
        .clipShape(Circle())
        .accessibilityLabel(Text("Profile photo"))
        .task(id: uri) {
            await loadImage()
        }
    }

    private var placeholder: some View {
        Circle()
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

        let data = try await PubkyService.fetchFile(uri: uri)
        let blobData = try await resolveImageData(data, originalUri: uri)

        guard let image = UIImage(data: blobData) else {
            throw PubkyImageError.decodingFailed(blobData.count)
        }

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
        return try await PubkyService.fetchFile(uri: src)
    }
}

private enum PubkyImageError: LocalizedError {
    case decodingFailed(Int)
    case crossUserRedirect

    var errorDescription: String? {
        switch self {
        case let .decodingFailed(bytes):
            return "Could not decode image blob (\(bytes) bytes)"
        case .crossUserRedirect:
            return "Image descriptor references a different user's namespace"
        }
    }
}

/// Two-tier cache (memory + disk) so profile images persist across app launches
/// and multiple PubkyImage views with the same URI don't re-fetch.
final class PubkyImageCache: @unchecked Sendable {
    static let shared = PubkyImageCache()

    private var memoryCache: [String: UIImage] = [:]
    private let lock = NSLock()
    private let diskQueue = DispatchQueue(label: "pubky-image-cache-disk", qos: .utility)
    private let diskDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDirectory = caches.appendingPathComponent("pubky-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Fast memory-only check — never blocks behind disk I/O, safe from the main thread.
    func memoryImage(for uri: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache[uri]
    }

    /// Full lookup (memory + disk). Disk I/O runs on a dedicated queue to avoid blocking cooperative threads.
    func image(for uri: String) async -> UIImage? {
        lock.lock()
        if let memoryHit = memoryCache[uri] {
            lock.unlock()
            return memoryHit
        }
        lock.unlock()

        return await withCheckedContinuation { continuation in
            diskQueue.async { [self] in
                let path = diskPath(for: uri)
                guard let diskData = try? Data(contentsOf: path),
                      let diskImage = UIImage(data: diskData)
                else {
                    continuation.resume(returning: nil)
                    return
                }

                lock.lock()
                memoryCache[uri] = diskImage
                lock.unlock()
                continuation.resume(returning: diskImage)
            }
        }
    }

    func store(_ image: UIImage, data: Data, for uri: String) {
        lock.lock()
        memoryCache[uri] = image
        lock.unlock()

        diskQueue.async { [diskDirectory] in
            let hash = Self.diskHash(for: uri)
            let path = diskDirectory.appendingPathComponent(hash)
            try? data.write(to: path, options: .atomic)
        }
    }

    func clear() async {
        lock.lock()
        memoryCache.removeAll()
        lock.unlock()

        await withCheckedContinuation { continuation in
            diskQueue.async { [diskDirectory] in
                try? FileManager.default.removeItem(at: diskDirectory)
                try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
                continuation.resume()
            }
        }
    }

    private static func diskHash(for uri: String) -> String {
        let data = Data(uri.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func diskPath(for uri: String) -> URL {
        diskDirectory.appendingPathComponent(Self.diskHash(for: uri))
    }
}
