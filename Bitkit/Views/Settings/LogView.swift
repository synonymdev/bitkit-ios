//
//  LogView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/16.
//

import SwiftUI
import UIKit

struct LogView: View {
    @State private var logFiles: [LogFile] = []
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        List {
            ForEach(logFiles) { logFile in
                NavigationLink(destination: LogContentView(logFile: logFile)) {
                    VStack(alignment: .leading) {
                        Text(logFile.displayName)
                            .font(.headline)
                        Text(logFile.url.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Log Files")
        .navigationBarItems(trailing: 
            Button(action: {
                showingDeleteConfirmation = true
            }) {
                Image(systemName: "trash")
            }
            .disabled(logFiles.isEmpty)
        )
        .alert("Delete All Logs", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteAllLogs()
            }
        } message: {
            Text("Are you sure you want to delete all log files? This action cannot be undone.")
        }
        .task {
            loadLogFiles()
        }
    }
    
    private func loadLogFiles() {
        var files: [LogFile] = []
        
        let logDirectory = URL(fileURLWithPath: Env.logDirectory)
        if let logURLs = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) {
            let logFiles = logURLs
                .filter { $0.pathExtension == "log" }
                .map { url -> LogFile in
                    let fileName = url.lastPathComponent
                    let components = fileName.components(separatedBy: "_")
                    
                    // First component is the service name (e.g., "bitkit" or "ldk")
                    let serviceName = components.first?.capitalized ?? "Unknown"
                    
                    // Format the date from the timestamp component (should be near the end)
                    let timestamp = components.count >= 3 ? components[components.count - 2] : ""
                    
                    // Create a display name showing service and date
                    let displayName = "\(serviceName) Log: \(timestamp)"
                    
                    return LogFile(displayName: displayName, url: url)
                }
                .sorted { (lhs, rhs) -> Bool in
                    // Try to get creation dates, fall back to modification dates if needed
                    let lhsResourceValues = try? lhs.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    let rhsResourceValues = try? rhs.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    
                    let lhsDate = lhsResourceValues?.creationDate ?? lhsResourceValues?.contentModificationDate ?? Date.distantPast
                    let rhsDate = rhsResourceValues?.creationDate ?? rhsResourceValues?.contentModificationDate ?? Date.distantPast
                    
                    // Sort descending (newest first)
                    return lhsDate > rhsDate
                }
            
            files.append(contentsOf: logFiles)
        }
        
        logFiles = files
    }
    
    private func deleteAllLogs() {
        let fileManager = FileManager.default
        
        for logFile in logFiles {
            try? fileManager.removeItem(at: logFile.url)
        }
        
        // Refresh the list
        loadLogFiles()
    }
}

// Model representing a log file
struct LogFile: Identifiable {
    var id: String { url.lastPathComponent }
    let displayName: String
    let url: URL
}

// View to display the content of a log file
struct LogContentView: View {
    let logFile: LogFile
    @State private var lines: [String] = []
    @State private var shouldScrollToBottom = false
    @State private var showShareSheet = false
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 8))
                        .multilineTextAlignment(.leading)
                        .foregroundColor(line.contains("ERROR") ? .red : .greenAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onChange(of: shouldScrollToBottom) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
        .navigationTitle(logFile.displayName)
        .navigationBarItems(
            trailing:
                Button(action: { showShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                }
        )
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [prepareFileForSharing(logFile.url)])
        }
        .task {
            await loadLog()
        }
    }
    
    @MainActor
    func loadLog() async {
        do {
            if FileManager.default.fileExists(atPath: logFile.url.path) {
                let text = try String(contentsOf: logFile.url, encoding: .utf8)
                lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                lines = ["Log file not found"]
            }
        } catch {
            lines = ["Failed to load log file: \(error.localizedDescription)"]
        }
        
        shouldScrollToBottom = true
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastLine = lines.last {
            withAnimation {
                proxy.scrollTo(lastLine, anchor: .bottom)
            }
        }
        shouldScrollToBottom = false
    }
    
    private func prepareFileForSharing(_ sourceURL: URL) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent(sourceURL.lastPathComponent)
        
        try? FileManager.default.removeItem(at: destURL)
        
        do {
            let content = try String(contentsOf: sourceURL, encoding: .utf8)
            try content.write(to: destURL, atomically: true, encoding: .utf8)
            return destURL
        } catch {
            print("Error preparing file for sharing: \(error)")
            return sourceURL
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        LogView()
    }
    .preferredColorScheme(.dark)
}
