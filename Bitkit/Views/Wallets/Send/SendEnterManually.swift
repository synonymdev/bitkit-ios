//
//  SendEnterManually.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SendEnterManually: View {
    @EnvironmentObject var app: AppViewModel
    @State private var text = ""
    @FocusState private var isTextEditorFocused: Bool

    init() {
        UITextView.appearance().backgroundColor = .clear
    }

    var body: some View {
        VStack {
            TextEditor(text: $text)
                .focused($isTextEditorFocused)
                .frame(height: 200)
                .transparentScrolling()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

            Spacer()

            Button("Continue") {
                do {
                    let data = try ScannedData(text)
                    Logger.debug("Pasted data: \(data)")
                    app.scannedData = data

                    Haptics.play(.pastedFromClipboard)

                    // TODO: nav to next view
                } catch {
                    Logger.error(error, context: "Failed to read data from text editor")
                    app.toast(error)
                }
            }
        }
        .padding()
        .navigationTitle("Send Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isTextEditorFocused = true
        }
    }
}

#Preview {
    SendEnterManually()
        .environmentObject(AppViewModel())
}
