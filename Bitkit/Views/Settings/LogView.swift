//
//  LogView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/16.
//

import SwiftUI

struct LogView: View {
    @State var lines: [String] = []
    
    var body: some View {
        List {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 8))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .listStyle(.plain)
        .onAppear {
            loadLog()
        }
    }
    
    func loadLog() {
        let dir = Env.ldkStorage(walletIndex: LightningService.shared.currentWalletIndex)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")
        
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            lines = text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        } catch {
            lines = ["Failed to load log file"]
        }
    }
}

#Preview {
    LogView()
}
