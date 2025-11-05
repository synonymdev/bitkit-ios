import SwiftUI

struct ReceiveEdit: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var transfer: TransferViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(\.dismiss) private var dismiss

    @Binding var navigationPath: [ReceiveRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var note = ""
    @State private var isAmountInputFocused: Bool = false
    @FocusState private var isNoteEditorFocused: Bool

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__receive_specify"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(viewModel: amountViewModel, isFocused: isAmountInputFocused)
                    .padding(.bottom, isAmountInputFocused ? 0 : 32)
                    .onTapGesture {
                        if isAmountInputFocused {
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        } else {
                            isAmountInputFocused = true
                        }
                    }
                    .accessibilityIdentifier("ReceiveNumberPadTextField")

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
                            .frame(minHeight: 30, maxHeight: 50)
                            .onSubmit {
                                isNoteEditorFocused = false
                            }
                            .accessibilityIdentifier("ReceiveNote")
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
                            icon: Image("tag").foregroundColor(.brandAccent)
                        ) {
                            navigationPath.append(.tag)
                        }
                        .accessibilityIdentifier("TagsAdd")
                    }

                    Spacer()

                    CustomButton(title: t("wallet__receive_show_qr")) {
                        Task {
                            await onShowQR()
                        }
                    }
                    .buttonBottomPadding(isFocused: isNoteEditorFocused)
                    .accessibilityIdentifier("ShowQrReceive")
                }
            }

            if isAmountInputFocused {
                Spacer()

                VStack(spacing: 0) {
                    numberPadButtons

                    NumberPad(
                        type: amountViewModel.getNumberPadType(currency: currency),
                        errorKey: amountViewModel.errorKey
                    ) { key in
                        amountViewModel.handleNumberPadInput(key, currency: currency)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ReceiveNumberField")

                    CustomButton(title: t("common__continue")) {
                        isAmountInputFocused = false
                    }
                    .accessibilityIdentifier("ReceiveNumberPadSubmit")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ReceiveNumberPad")
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
                wallet.invoiceAmountSats = amountSats
                wallet.invoiceNote = note
                try await wallet.refreshBip21(forceRefreshBolt11: true)

                // Check if CJIT flow should be shown
                if needsAdditionalCjit() {
                    let entry = try await blocktank.createCjit(amountSats: amountSats, description: note)
                    navigationPath.append(.cjitConfirm(entry: entry, receiveAmountSats: amountSats, isAdditional: true))
                } else {
                    dismiss()
                }
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

    private func needsAdditionalCjit() -> Bool {
        let isGeoBlocked = app.isGeoBlocked ?? false
        let minimumAmount = blocktank.minCjitSats ?? 0
        let inboundCapacity = wallet.totalInboundLightningSats ?? 0
        let invoiceAmount = amountViewModel.amountSats

        // Calculate maxClientBalance using TransferViewModel
        let maxChannelSize = blocktank.info?.options.maxChannelSizeSat ?? 0
        let maxClientBalance = transfer.getMaxClientBalance(maxChannelSize: UInt64(maxChannelSize))

        if
            // user is geo-blocked
            isGeoBlocked ||
            // failed to get minimum amount
            minimumAmount == 0 ||
            // amount is less than minimum CJIT amount
            invoiceAmount < minimumAmount ||
            // there is enough inbound capacity
            invoiceAmount <= inboundCapacity ||
            // amount is above the maximum client balance
            invoiceAmount > maxClientBalance
        {
            return false
        }

        return true
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
                .accessibilityIdentifier("ReceiveNumberPadUnit")
            }
        }
        .padding(.bottom, 8)

        Divider()
    }
}
