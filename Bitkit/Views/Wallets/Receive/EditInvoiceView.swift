//
//  EditInvoiceView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/03/21.
//

import SwiftUI

struct EditInvoiceView: View {
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var amountSats: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var noteText = ""
    @FocusState private var isNoteEditorFocused: Bool
    @FocusState private var isAmountInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats, showConversion: true, shouldAutoFocus: false) { newSats in
                    Haptics.play(.buttonTap)
                    amountSats = newSats
                    overrideSats = nil
                }
                .focused($isAmountInputFocused)
                .padding(.vertical, 16)

                CaptionText(NSLocalizedString("wallet__note", comment: "").uppercased())
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack(alignment: .topLeading) {
                    if noteText.isEmpty {
                        BodySText(NSLocalizedString("wallet__receive_note_placeholder", comment: ""), textColor: .textSecondary)
                            .padding(20)
                    }

                    TextEditor(text: $noteText)
                        .focused($isNoteEditorFocused)
                        .padding(EdgeInsets(top: -10, leading: -5, bottom: -5, trailing: -5))
                        .padding(20)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .font(.custom(Fonts.bold, size: 22))
                        .foregroundColor(.textPrimary)
                        .accentColor(.brandAccent)
                        .frame(maxHeight: 100)
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)

                Spacer()

                if !isAmountInputFocused && !isNoteEditorFocused {
                    Image("coin-stack")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(alignment: .bottom)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if isAmountInputFocused && !isNoteEditorFocused {
                    optionButtonsRow
                }
            }
            .padding(.horizontal, 16)

            Spacer()

            CustomButton(title: NSLocalizedString("wallet__receive_show_qr", comment: "")) {
                // Wait until node is running if it's in starting state
                if await wallet.waitForNodeToRun() {
                    do {
                        wallet.invoiceAmountSats = amountSats
                        wallet.invoiceNote = noteText
                        try await wallet.refreshBip21(forceRefreshBolt11: true)
                        presentationMode.wrappedValue.dismiss()
                    } catch {
                        app.toast(error)
                    }
                } else {
                    // Show error if node is not running or timed out
                    app.toast(type: .warning, title: "Lightning not ready", description: "Lightning node must be running to create an invoice")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .sheetBackground()
        .navigationTitle(NSLocalizedString("wallet__receive_specify", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            primaryDisplay = currency.primaryDisplay
            // Initialize with existing values from wallet model
            if wallet.invoiceAmountSats > 0 {
                amountSats = wallet.invoiceAmountSats
                overrideSats = wallet.invoiceAmountSats
            }
            if !wallet.invoiceNote.isEmpty {
                noteText = wallet.invoiceNote
            }
        }
    }

    @ViewBuilder
    private var optionButtonsRow: some View {
        HStack(alignment: .bottom) {
            Spacer()
            HStack(spacing: 16) {
                NumberPadActionButton(
                    text: primaryDisplay == .bitcoin ? currency.selectedCurrency : "Bitcoin",
                    imageName: "transfer-brand",
                    color: Color.brandAccent
                ) {
                    withAnimation {
                        primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
                    }
                }
            }
        }
        .padding(.vertical, 8)

        Divider()
    }
}

#Preview {
    NavigationStack {
        EditInvoiceView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
    }
}
