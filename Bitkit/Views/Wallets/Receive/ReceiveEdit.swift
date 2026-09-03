import BitkitCore
import SwiftUI

struct ReceiveEdit: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var tagManager: TagManager
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests
    @Environment(\.dismiss) private var dismiss

    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    @Binding var navigationPath: [ReceiveRoute]
    let sourceTab: ReceiveQr.ReceiveTab
    let onSendPaymentRequest: (PaykitPaymentRequestDraft) -> Void

    @State private var amountViewModel = AmountInputViewModel()
    @State private var note = ""
    @State private var isAmountInputFocused: Bool = false
    @FocusState private var isNoteEditorFocused: Bool

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var liquiditySource: ReceiveLiquiditySource {
        switch sourceTab {
        case .savings:
            return .savings
        case .unified:
            return .auto
        case .spending:
            return .spending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__receive_specify"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(
                    viewModel: amountViewModel,
                    showEditButton: !isAmountInputFocused,
                    isFocused: isAmountInputFocused,
                    testIdentifier: "ReceiveNumberPadTextField"
                )
                .padding(.bottom, isAmountInputFocused ? 0 : 32)
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

                    NoteTextEditor(
                        text: $note,
                        placeholder: t("wallet__receive_note_placeholder"),
                        testIdentifier: "ReceiveNote",
                        isFocused: $isNoteEditorFocused
                    )

                    if !isNoteEditorFocused {
                        VStack(alignment: .leading, spacing: 0) {
                            CaptionMText(t("wallet__tags"))
                                .padding(.top, 16)
                                .padding(.bottom, 8)

                            TagsListView(
                                tags: tagManager.selectedTagsArray,
                                icon: .close,
                                onAddTag: {
                                    navigationPath.append(.tag)
                                },
                                onTagDelete: { tag in
                                    Task {
                                        await deleteTag(tag)
                                    }
                                }
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()

                    if PaykitFeatureFlags.isUIAvailable,
                       isPaykitUIEnabled,
                       !paymentRequests.eligibleTargets.isEmpty
                    {
                        CustomButton(
                            title: t("wallet__payment_request_send"),
                            variant: .secondary,
                            isDisabled: amountSats == 0
                        ) {
                            onSendPaymentRequest(
                                PaykitPaymentRequestDraft(
                                    amountSats: amountSats,
                                    note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    expiresAt: PaymentRequestExpiration.week.date(from: .now)
                                )
                            )
                        }
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("PaymentRequestSendButton")
                    }

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

                var maxCjitAmountSats: UInt64?
                if needsCjitLimitsForAdditionalLiquidity() {
                    try? await blocktank.refreshMinCjitSats()
                    maxCjitAmountSats = try? await blocktank.maxCjitAmountSats()
                }

                switch additionalLiquidityAction(maxCjitAmountSats: maxCjitAmountSats) {
                case .none:
                    try await wallet.refreshBip21(forceRefreshBolt11: true)
                    dismiss()
                case .chooseAmount:
                    try await wallet.refreshBip21(forceRefreshBolt11: true)
                    navigationPath.append(.cjitAmount)
                case let .createCjit(amountSats):
                    let entry = try await blocktank.createCjit(amountSats: amountSats, description: note)
                    navigationPath.append(.cjitConfirm(entry: entry, receiveAmountSats: amountSats, isAdditional: true))
                case .geoBlocked:
                    navigationPath.append(.cjitGeoBlocked)
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

    private func deleteTag(_ tag: String) async {
        guard let paymentId = await wallet.paymentId(), !paymentId.isEmpty else { return }
        do {
            try await CoreService.shared.activity.removePreActivityMetadataTags(
                paymentId: paymentId,
                tags: [tag]
            )

            await MainActor.run {
                tagManager.removeTagFromSelection(tag)
            }
        } catch {
            app.toast(type: .error, title: "Failed to delete tag", description: error.localizedDescription)
        }
    }

    private func additionalLiquidityAction(maxCjitAmountSats: UInt64?) -> ReceiveAdditionalLiquidityAction {
        ReceiveLiquidityDecision.additionalLiquidityAction(
            source: liquiditySource,
            invoiceAmountSats: amountViewModel.amountSats,
            inboundCapacitySats: wallet.totalInboundLightningSats,
            minCjitSats: blocktank.minCjitSats,
            maxCjitAmountSats: maxCjitAmountSats,
            isGeoBlocked: GeoService.shared.isGeoBlocked
        )
    }

    private func needsCjitLimitsForAdditionalLiquidity() -> Bool {
        ReceiveLiquidityDecision.needsCjitLimitsForAdditionalLiquidity(
            source: liquiditySource,
            invoiceAmountSats: amountViewModel.amountSats,
            inboundCapacitySats: wallet.totalInboundLightningSats,
            isGeoBlocked: GeoService.shared.isGeoBlocked
        )
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
