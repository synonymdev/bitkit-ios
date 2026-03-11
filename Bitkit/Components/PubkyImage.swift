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

    @ViewBuilder
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
        if let cached = PubkyImageCache.shared.image(for: uri) {
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
            return data
        }

        Logger.debug("File descriptor found, fetching blob from: \(src)", context: "PubkyImage")
        return try await PubkyService.fetchFile(uri: src)
    }
}

private enum PubkyImageError: LocalizedError {
    case decodingFailed(Int)

    var errorDescription: String? {
        switch self {
        case let .decodingFailed(bytes):
            return "Could not decode image blob (\(bytes) bytes)"
        }
    }
}

/// Two-tier cache (memory + disk) so profile images persist across app launches
/// and multiple PubkyImage views with the same URI don't re-fetch.
final class PubkyImageCache: @unchecked Sendable {
    static let shared = PubkyImageCache()

    private var memoryCache: [String: UIImage] = [:]
    private let ioQueue = DispatchQueue(label: "pubky-image-cache", qos: .utility)
    private let diskDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDirectory = caches.appendingPathComponent("pubky-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Fast memory-only check — safe to call from the main thread.
    func memoryImage(for uri: String) -> UIImage? {
        ioQueue.sync { memoryCache[uri] }
    }

    /// Full lookup (memory + disk). Call from a background context to avoid blocking the main thread.
    func image(for uri: String) -> UIImage? {
        ioQueue.sync {
            if let memoryHit = memoryCache[uri] {
                return memoryHit
            }

            let path = diskPath(for: uri)
            guard let diskData = try? Data(contentsOf: path),
                  let diskImage = UIImage(data: diskData)
            else {
                return nil
            }

            memoryCache[uri] = diskImage
            return diskImage
        }
    }

    func store(_ image: UIImage, data: Data, for uri: String) {
        ioQueue.sync {
            memoryCache[uri] = image
            let path = diskPath(for: uri)
            try? data.write(to: path, options: .atomic)
        }
    }

    func clear() {
        ioQueue.sync {
            memoryCache.removeAll()
            try? FileManager.default.removeItem(at: diskDirectory)
            try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
    }

    private func diskPath(for uri: String) -> URL {
        let data = Data(uri.utf8)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hash)
    }
}
