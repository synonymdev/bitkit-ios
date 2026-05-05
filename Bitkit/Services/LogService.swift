import Foundation

class LogService {
    static let shared = LogService()
    private let zipService = ZipService()

    private init() {}

    /// Creates a zip file of the logs directory and returns the file URL
    func zipLogs() -> URL? {
        let logDirectory = URL(fileURLWithPath: Env.logDirectory)

        // Check if log directory exists
        guard FileManager.default.fileExists(atPath: logDirectory.path) else {
            Logger.error("Log directory does not exist: \(logDirectory.path)")
            return nil
        }

        do {
            // Get all log files in the directory
            let logFiles = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" }

            guard !logFiles.isEmpty else {
                Logger.error("No log files found in directory: \(logDirectory.path)")
                return nil
            }

            // Create filename based on current timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
            let timestamp = dateFormatter.string(from: Date())
            let fileName = "bitkit_logs_\(timestamp)"
            let filesToZip = logFiles.map { FileToZip.existingFile($0) }
            return try zipService.createZipAtTmp(zipFilename: fileName, filesToZip: filesToZip)

        } catch {
            Logger.error(error, context: "Failed to create zip file for logs")
            return nil
        }
    }

    /// Creates a zip file with only the latest log files for support requests
    func zipLogsForSupport() -> (logs: String, fileName: String)? {
        let logDirectory = URL(fileURLWithPath: Env.logDirectory)

        // Check if log directory exists
        guard FileManager.default.fileExists(atPath: logDirectory.path) else {
            Logger.error("Log directory does not exist: \(logDirectory.path)")
            return nil
        }

        do {
            // Get all log files in the directory
            let allLogFiles = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" }

            guard !allLogFiles.isEmpty else {
                Logger.error("No log files found in directory: \(logDirectory.path)")
                return nil
            }

            // Separate and sort log files by type using file modification date
            let bitkitFiles = allLogFiles.filter { $0.lastPathComponent.hasPrefix("bitkit_foreground_") }
                .sorted { getFileModificationDate($0) > getFileModificationDate($1) }

            let ldkFiles = allLogFiles.filter { $0.lastPathComponent.hasPrefix("ldk_foreground_") }
                .sorted { getFileModificationDate($0) > getFileModificationDate($1) }

            // Take only the latest 5 of each type
            let latestBitkitFiles = Array(bitkitFiles.prefix(5))
            let latestLdkFiles = Array(ldkFiles.prefix(5))

            let filesToZip = latestBitkitFiles + latestLdkFiles

            guard !filesToZip.isEmpty else {
                Logger.error("No bitkit_foreground or ldk_foreground log files found")
                return nil
            }

            // Create filename based on current timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
            let timestamp = dateFormatter.string(from: Date())
            let fileName = "bitkit_support_logs_\(timestamp)"

            let zipInputs = filesToZip.map { FileToZip.existingFile($0) }
            let zipData = try zipService.getZipData(zipFilename: fileName, filesToZip: zipInputs)
            let base64Logs = zipData.base64EncodedString()
            let finalFileName = "\(fileName).zip"

            Logger.info("Support logs zip created: \(zipData.count) bytes, base64: \(base64Logs.count) characters")

            return (logs: base64Logs, fileName: finalFileName)

        } catch {
            Logger.error(error, context: "Failed to create zip file for support request")
            return nil
        }
    }

    /// Gets file modification date for sorting
    private func getFileModificationDate(_ fileURL: URL) -> Date {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attributes[.modificationDate] as? Date ?? Date.distantPast
        } catch {
            return Date.distantPast
        }
    }
}
