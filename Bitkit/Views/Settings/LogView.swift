//
//  LogView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/16.
//

import SwiftUI

struct LogView: View {
    @State var lines: [String] = []
    @State private var shouldScrollToBottom = false

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
        .task {
            await loadLog()
        }
    }

    @MainActor
    func loadLog() async {
        let dir = Env.ldkStorage(walletIndex: LightningService.shared.currentWalletIndex)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")

        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            lines = ["Failed to load log file"]
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
}

#Preview {
    LogView()
}
