import Foundation

// MARK: - Extensions

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

// MARK: - Errors

enum CreateZipError: Swift.Error {
    case urlNotADirectory(URL)
    case invalidFilename(String)
    case failedToCreateZIP(Swift.Error)
    case failedToGetDataFromZipURL
}

// MARK: - FileToZip

enum FileToZip {
    case data(Data, filename: String)
    case existingFile(URL)
    case renamedFile(URL, toFilename: String)
}

extension FileToZip {
    static func text(_ text: String, filename: String) -> FileToZip {
        .data(text.data(using: .utf8) ?? Data(), filename: filename)
    }
}

extension FileToZip {
    func prepareInDirectory(directoryURL: URL, usedFilenames: inout Set<String>) throws {
        func uniqueDestinationURL(for suggestedFilename: String) throws -> URL {
            let sanitizedFilename = Self.sanitizedFilename(suggestedFilename)
            guard !sanitizedFilename.isEmpty else {
                throw CreateZipError.invalidFilename(suggestedFilename)
            }

            let baseName = URL(fileURLWithPath: sanitizedFilename).deletingPathExtension().lastPathComponent
            let fileExtension = URL(fileURLWithPath: sanitizedFilename).pathExtension

            var candidateFilename = sanitizedFilename
            var duplicateIndex = 1
            while usedFilenames.contains(candidateFilename) {
                let suffixedBaseName = "\(baseName)_\(duplicateIndex)"
                candidateFilename = fileExtension.isEmpty
                    ? suffixedBaseName
                    : "\(suffixedBaseName).\(fileExtension)"
                duplicateIndex += 1
            }

            usedFilenames.insert(candidateFilename)
            return directoryURL.appendingPathComponent(candidateFilename)
        }

        switch self {
        case let .data(data, filename: filename):
            let fileURL = try uniqueDestinationURL(for: filename)
            try data.write(to: fileURL)
        case let .existingFile(existingFileURL):
            let newFileURL = try uniqueDestinationURL(for: existingFileURL.lastPathComponent)
            try FileManager.default.copyItem(at: existingFileURL, to: newFileURL)
        case let .renamedFile(existingFileURL, toFilename: filename):
            let newFileURL = try uniqueDestinationURL(for: filename)
            try FileManager.default.copyItem(at: existingFileURL, to: newFileURL)
        }
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - ZipService

final class ZipService {
    init() {}

    func createZip(
        zipFinalURL: URL,
        fromDirectory directoryURL: URL
    ) throws -> URL {
        // see URL extension below
        guard directoryURL.isDirectory else {
            throw CreateZipError.urlNotADirectory(directoryURL)
        }

        var fileManagerError: Swift.Error?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: directoryURL,
            options: .forUploading,
            error: &coordinatorError
        ) { zipAccessURL in
            do {
                if FileManager.default.fileExists(atPath: zipFinalURL.path) {
                    _ = try FileManager.default.replaceItemAt(zipFinalURL, withItemAt: zipAccessURL)
                } else {
                    try FileManager.default.moveItem(at: zipAccessURL, to: zipFinalURL)
                }
            } catch {
                fileManagerError = error
            }
        }
        if let error = coordinatorError ?? fileManagerError {
            throw CreateZipError.failedToCreateZIP(error)
        }
        return zipFinalURL
    }

    func createZipAtTmp(
        zipFilename: String,
        zipExtension: String = "zip",
        fromDirectory directoryURL: URL
    ) throws -> URL {
        let finalURL = FileManager.default.temporaryDirectory
            .appending(path: zipFilename)
            .appendingPathExtension(zipExtension)
        return try createZip(
            zipFinalURL: finalURL,
            fromDirectory: directoryURL
        )
    }

    func createZipAtTmp(
        zipFilename: String,
        zipExtension: String = "zip",
        filesToZip: [FileToZip]
    ) throws -> URL {
        let directoryToZipURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: zipFilename)
        try FileManager.default.createDirectory(at: directoryToZipURL, withIntermediateDirectories: true, attributes: [:])
        var usedFilenames = Set<String>()
        for fileToZip in filesToZip {
            try fileToZip.prepareInDirectory(directoryURL: directoryToZipURL, usedFilenames: &usedFilenames)
        }
        defer {
            try? FileManager.default.removeItem(at: directoryToZipURL)
        }

        return try createZipAtTmp(
            zipFilename: zipFilename,
            zipExtension: zipExtension,
            fromDirectory: directoryToZipURL
        )
    }

    private func getZipData(zipFileURL: URL) throws -> Data {
        defer {
            try? FileManager.default.removeItem(at: zipFileURL)
        }
        guard let data = FileManager.default.contents(atPath: zipFileURL.path) else {
            throw CreateZipError.failedToGetDataFromZipURL
        }
        return data
    }

    func getZipData(
        zipFilename: String = UUID().uuidString,
        fromDirectory directoryURL: URL
    ) throws -> Data {
        let zipURL = try createZipAtTmp(
            zipFilename: zipFilename,
            fromDirectory: directoryURL
        )
        return try getZipData(zipFileURL: zipURL)
    }

    func getZipData(
        zipFilename: String = UUID().uuidString,
        filesToZip: [FileToZip]
    ) throws -> Data {
        let zipURL = try createZipAtTmp(
            zipFilename: zipFilename,
            filesToZip: filesToZip
        )
        return try getZipData(zipFileURL: zipURL)
    }
}
