import SwiftUI

struct ReceiveEdit: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(\.dismiss) private var dismiss

    @Binding var navigationPath: [ReceiveRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var note = ""
    @State private var isAmountInputFocused: Bool = false
    @FocusState private var isNoteEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__receive_specify"))

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(viewModel: amountViewModel, isFocused: isAmountInputFocused)
                    .padding(.bottom, 40)
                    .onTapGesture {
                        if isAmountInputFocused {
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        } else {
                            isAmountInputFocused = true
                        }
                    }

                if !isAmountInputFocused {
                    CaptionMText(t("wallet__note"))
                        .padding(.bottom, 8)

                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            BodySSBText(t("wallet__receive_note_placeholder"), textColor: .textSecondary)
                        }

                        TextEditor(text: $note)
                            .focused($isNoteEditorFocused)
                            .font(.custom(Fonts.semiBold, size: 15))
                            .foregroundColor(.textPrimary)
                            .accentColor(.brandAccent)
                            .submitLabel(.done)
                            .scrollContentBackground(.hidden)
                            .padding(EdgeInsets(top: -8, leading: -5, bottom: -5, trailing: -5))
                            .frame(minHeight: 50, maxHeight: 50)
                            .onSubmit {
                                isNoteEditorFocused = false
                            }
                    }
                    .padding()
                    .background(Color.white06)
                    .cornerRadius(8)

                    if !isNoteEditorFocused {
                        CaptionMText(t("wallet__tags"))
                            .padding(.top, 16)
                            .padding(.bottom, 8)

                        CustomButton(
                            title: t("wallet__tags_add"),
                            size: .small,
                            icon: Image("tag").foregroundColor(.brandAccent),
                        ) {
                            navigationPath.append(.tag)
                        }

                        Spacer()

                        Image("coin-stack")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(alignment: .bottom)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Spacer()

                    CustomButton(title: t("wallet__receive_show_qr")) {
                        Task {
                            await onShowQR()
                        }
                    }
                    .padding(.bottom, isNoteEditorFocused ? 16 : 0)
                }
            }

            if isAmountInputFocused {
                Spacer()

                numberPadButtons

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(title: t("common__continue")) {
                    isAmountInputFocused = false
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .task {
            // Initialize with existing values from wallet model
            if wallet.invoiceAmountSats > 0 {
                amountViewModel.updateFromSats(wallet.invoiceAmountSats, currency: currency)
            }
            if !wallet.invoiceNote.isEmpty {
                note = wallet.invoiceNote
            }
        }
    }

    private func onShowQR() async {
        // Wait until node is running if it's in starting state
        if await wallet.waitForNodeToRun() {
            do {
                wallet.invoiceAmountSats = amountViewModel.amountSats
                wallet.invoiceNote = note
                try await wallet.refreshBip21(forceRefreshBolt11: true)
                dismiss()
            } catch {
                app.toast(error)
            }
        } else {
            // Show error if node is not running or timed out
            app.toast(
                type: .warning,
                title: "Lightning not ready",
                description: "Lightning node must be running to create an invoice"
            )
        }
    }

    @ViewBuilder
    private var numberPadButtons: some View {
        HStack(alignment: .bottom) {
            Spacer()
            HStack(spacing: 16) {
                NumberPadActionButton(
                    text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                    imageName: "arrow-up-down",
                    color: .brandAccent
                ) {
                    withAnimation {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }
                }
            }
        }
        .padding(.vertical, 8)

        Divider()
    }
}
