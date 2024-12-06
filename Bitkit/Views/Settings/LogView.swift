//
//  LogView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/16.
//

import SwiftUI
import UIKit

struct LogView: View {
    @State var lines: [String] = []
    @State private var shouldScrollToBottom = false
    @State private var logFileURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 8))
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.plain)
            .onChange(of: shouldScrollToBottom) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
        .navigationBarItems(trailing:
            Group {
                if logFileURL != nil {
                    Button(action: { showShareSheet = true }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        )
        .sheet(isPresented: $showShareSheet) {
            if let sourceURL = logFileURL {
                ShareSheet(activityItems: [prepareFileForSharing(sourceURL)])
            }
        }
        .task {
            await loadLog()
        }
    }

    @MainActor
    func loadLog() async {
        let dir = Env.ldkStorage(walletIndex: LightningService.shared.currentWalletIndex)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                logFileURL = fileURL
                let text = try String(contentsOf: fileURL, encoding: .utf8)
                lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                lines = ["Log file not found"]
                logFileURL = nil
            }
        } catch {
            lines = ["Failed to load log file"]
            logFileURL = nil
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
        let destURL = tempDir.appendingPathComponent("ldk_node_latest.log")
        
        try? FileManager.default.removeItem(at: destURL) // Remove any existing file
        
        do {
            // Read the content from the symbolic link
            let content = try String(contentsOf: sourceURL, encoding: .utf8)
            
            // Write the content to a new file
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
    LogView()
}
