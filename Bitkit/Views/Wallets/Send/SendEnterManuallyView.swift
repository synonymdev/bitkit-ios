//
//  SendEnterManually.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SendEnterManuallyView: View {
    @EnvironmentObject var app: AppViewModel
    @State private var text = ""
    @FocusState private var isTextEditorFocused: Bool

    @State private var showSendAmountView = false
    @State private var showSendConfirmationView = false

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
                handleContinue()
            }
        }
        .padding()
        .navigationTitle("Send Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isTextEditorFocused = true
        }
        .background(
            NavigationLink(
                destination: SendAmountView(),
                isActive: $showSendAmountView
            ) { EmptyView() }
        )
        .background(
            NavigationLink(
                destination: SendConfirmationView(),
                isActive: $showSendConfirmationView
            ) { EmptyView() }
        )
    }

    func handleContinue() {
        let uri = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else {
            Haptics.notify(.error)
            Logger.error("Empty text field")
            return
        }

        Haptics.play(.medium)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)

                // If nil then it's not an invoice we're dealing with
                if app.invoiceRequiresCustomAmount == true {
                    showSendAmountView = true
                } else if app.invoiceRequiresCustomAmount == false {
                    showSendConfirmationView = true
                }
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(error)
            }
        }
    }
}

#Preview {
    SendEnterManuallyView()
        .environmentObject(AppViewModel())
}
