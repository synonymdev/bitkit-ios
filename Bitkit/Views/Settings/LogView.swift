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
        .task {
            loadLogFiles()
        }
    }
    
    private func loadLogFiles() {
        var files: [LogFile] = []
        
        let ldkLogURL = URL(fileURLWithPath: Env.ldkLogFile(walletIndex: LightningService.shared.currentWalletIndex))
        if FileManager.default.fileExists(atPath: ldkLogURL.path) {
            files.append(LogFile(displayName: "LDK Log", url: ldkLogURL, type: .ldk))
        }
        
        let logDirectory = URL(fileURLWithPath: Env.bitkitLogFileDirectory)
        if let logURLs = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) {
            let bitkitLogs = logURLs
                .filter { $0.pathExtension == "log" }
                .map { LogFile(displayName: formatLogFileName($0.lastPathComponent), url: $0, type: .bitkit) }
                .sorted { (lhs, rhs) -> Bool in
                    let lhsDate = try? lhs.url.resourceValues(forKeys: [.creationDateKey]).creationDate
                    let rhsDate = try? rhs.url.resourceValues(forKeys: [.creationDateKey]).creationDate
                    return (lhsDate ?? Date.distantPast) > (rhsDate ?? Date.distantPast)
                }
            
            files.append(contentsOf: bitkitLogs)
        }
        
        logFiles = files
    }
    
    private func formatLogFileName(_ filename: String) -> String {
        var name = filename
        if name.hasPrefix("bitkit_") {
            name = String(name.dropFirst(7))
        }
        if name.hasSuffix(".log") {
            name = String(name.dropLast(4))
        }
        
        name = name.replacingOccurrences(of: "_", with: " ")
        
        if let dateEndIndex = name.firstIndex(of: " ") {
            let dateString = String(name[..<dateEndIndex])
            let timeString = String(name[dateEndIndex...])
            
            return "Bitkit Log: \(dateString)"
        }
        
        return "Bitkit Log: \(name)"
    }
}

// Model representing a log file
struct LogFile: Identifiable {
    var id: String { url.lastPathComponent }
    let displayName: String
    let url: URL
    let type: LogType
    
    enum LogType {
        case ldk
        case bitkit
    }
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
                        .foregroundColor(.greenAccent)
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
    NavigationView {
        LogView()
    }
    .preferredColorScheme(.dark)
}
