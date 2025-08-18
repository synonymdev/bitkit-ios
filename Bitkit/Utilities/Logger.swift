import Foundation

class Logger {
    private init() {}
    static let queue = DispatchQueue(label: "bitkit.log", qos: .utility)
    static let maxLogSizeBytes: UInt64 = 5 * 1024 * 1024 // 5 MB
    static let sessionLogFile: String = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        let timestamp = dateFormatter.string(from: Date())

        let baseDir = Env.logDirectory
        let contextPrefix = Env.currentExecutionContext.filenamePrefix
        let sessionLogPath = "\(baseDir)/bitkit_\(contextPrefix)_\(timestamp).log"

        // Create directory if it doesn't exist
        let directory = URL(fileURLWithPath: baseDir)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("Failed to create log directory: \(error)")
            }
        }

        // Run cleanup in background, pretty much when the app starts
        DispatchQueue.global(qos: .background).async {
            Logger.cleanUpOldLogFiles()
        }

        print("Bitkit logger initialized with session log: \(sessionLogPath)")

        return sessionLogPath
    }()

    static func info(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("INFOℹ️: \(message)", context: context, file: file, function: function, line: line)
    }

    static func debug(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("DEBUG: \(message)", context: context, file: file, function: function, line: line)
    }

    static func warn(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("WARN⚠️: \(message)", context: context, file: file, function: function, line: line)
    }

    static func error(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("ERROR❌: \(message)", context: context, file: file, function: function, line: line)
    }

    static func test(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("🧪🧪🧪: \(message)", context: context, file: file, function: function, line: line)
    }

    static func performance(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        handle("PERF: \(message)", context: context, file: file, function: function, line: line)
    }

    private static func handle(_ message: Any, context: String = "", file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let line = "\(message) \(context == "" ? "" : "- \(context) ")[\(fileName): \(function) line: \(line)]"

        print(line)

        queue.async {
            writeToFile(line)
        }
    }

    private static func writeToFile(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp) UTC] \(message)\n"

        let logFilePath = sessionLogFile

        // Write to file
        if FileManager.default.fileExists(atPath: logFilePath) {
            if let fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logFilePath)) {
                fileHandle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
        } else {
            do {
                try logMessage.write(toFile: logFilePath, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to write to log file: \(error)")
            }
        }
    }

    // Cleans up both bitkit and ldk log files
    static func cleanUpOldLogFiles(maxTotalSizeMB: Int = 20) {
        queue.async {
            let baseDir = Env.logDirectory

            let fileManager = FileManager.default
            guard let fileURLs = try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: baseDir),
                                                                      includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                                      options: .skipsHiddenFiles)
            else {
                return
            }

            // Filter log files and get their sizes and creation dates
            var logFiles: [(url: URL, size: UInt64, date: Date)] = []
            var totalSize: UInt64 = 0

            for fileURL in fileURLs {
                if fileURL.pathExtension == "log" {
                    guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                          let creationDate = attributes[.creationDate] as? Date,
                          let fileSize = attributes[.size] as? UInt64
                    else {
                        continue
                    }

                    logFiles.append((fileURL, fileSize, creationDate))
                    totalSize += fileSize
                }
            }

            // Sort by creation date (oldest first)
            logFiles.sort { $0.date < $1.date }

            // Delete oldest files until we're under the size limit
            let maxSizeBytes = UInt64(maxTotalSizeMB) * 1024 * 1024

            for logFile in logFiles {
                if totalSize <= maxSizeBytes {
                    break
                }

                do {
                    try fileManager.removeItem(at: logFile.url)
                    totalSize -= logFile.size
                } catch {
                    print("Failed to delete log file: \(error)")
                }
            }
        }
    }
}
