import SwiftUI

struct ReceiveEdit: View {
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @Environment(\.dismiss) private var dismiss
    @Binding var navigationPath: [ReceiveRoute]
    @State private var amountSats: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var noteText = ""
    @FocusState private var isNoteEditorFocused: Bool
    @FocusState private var isAmountInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("wallet__receive_specify"))

            VStack(alignment: .leading, spacing: 0) {
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats, showConversion: true, shouldAutoFocus: false) {
                    newSats in
                    Haptics.play(.buttonTap)
                    amountSats = newSats
                    overrideSats = nil
                }
                .focused($isAmountInputFocused)
                .padding(.bottom, 32)

                CaptionMText(localizedString("wallet__note"))
                    .padding(.bottom, 8)

                ZStack(alignment: .topLeading) {
                    if noteText.isEmpty {
                        BodySSBText(localizedString("wallet__receive_note_placeholder"), textColor: .textSecondary)
                            .padding(16)
                    }

                    TextEditor(text: $noteText)
                        .focused($isNoteEditorFocused)
                        .padding(EdgeInsets(top: -10, leading: -5, bottom: -5, trailing: -5))
                        .padding(16)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .font(.custom(Fonts.semiBold, size: 15))
                        .foregroundColor(.textPrimary)
                        .accentColor(.brandAccent)
                        .frame(maxHeight: 100)
                }
                .background(Color.white06)
                .cornerRadius(8)

                CaptionMText(localizedString("wallet__tags"))
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                CustomButton(
                    title: localizedString("wallet__tags_add"),
                    size: .small,
                    icon: Image("tag").foregroundColor(.brandAccent),
                ) {
                    navigationPath.append(.tag)
                }

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

            Spacer()

            CustomButton(title: localizedString("wallet__receive_show_qr")) {
                // Wait until node is running if it's in starting state
                if await wallet.waitForNodeToRun() {
                    do {
                        wallet.invoiceAmountSats = amountSats
                        wallet.invoiceNote = noteText
                        try await wallet.refreshBip21(forceRefreshBolt11: true)
                        dismiss()
                    } catch {
                        app.toast(error)
                    }
                } else {
                    // Show error if node is not running or timed out
                    app.toast(type: .warning, title: "Lightning not ready", description: "Lightning node must be running to create an invoice")
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .task {
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
                    text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                    imageName: "transfer-brand",
                    color: Color.brandAccent
                ) {
                    withAnimation {
                        currency.togglePrimaryDisplay()
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
        ReceiveEdit(navigationPath: .constant([]))
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(WalletViewModel())
    }
}
