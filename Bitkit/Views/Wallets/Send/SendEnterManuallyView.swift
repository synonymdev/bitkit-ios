//
//  SendEnterManually.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SendEnterManuallyView: View {
    @EnvironmentObject var app: AppViewModel
    @Binding var navigationPath: [SendView]
    @State private var text = ""
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        VStack {
            SheetHeader(title: localizedString("wallet__send_bitcoin"), showBackButton: true)

            CaptionText(NSLocalizedString("wallet__send_to", comment: "").uppercased())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    TitleText(NSLocalizedString("wallet__send_address_placeholder", comment: ""), textColor: .textSecondary)
                        .padding(20)
                }

                TextEditor(text: $text)
                    .focused($isTextEditorFocused)
                    .padding(EdgeInsets(top: -10, leading: -5, bottom: -5, trailing: -5))
                    .padding(20)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .font(.custom(Fonts.bold, size: 22))
                    .foregroundColor(.textPrimary)
                    .accentColor(.brandAccent)
            }
            .background(Color.gray.opacity(0.2))
            .cornerRadius(8)

            Spacer()

            CustomButton(title: "Continue", isDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                await handleContinue()
            }
            .padding(.top)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isTextEditorFocused = true
        }
    }

    func handleContinue() async {
        let uri = text.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await app.handleScannedData(uri)

            // If nil then it's not an invoice we're dealing with
            if app.invoiceRequiresCustomAmount == true {
                navigationPath.append(.amount)
            } else if app.invoiceRequiresCustomAmount == false {
                navigationPath.append(.confirm)
            }
        } catch {
            Logger.error(error, context: "Failed to read data from clipboard")
            app.toast(error)
        }
    }
}

#Preview {
    SendEnterManuallyView(navigationPath: .constant([]))
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
