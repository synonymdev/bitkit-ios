import LDKNode
import SwiftUI

/// Review receive fee: the quote the primary node charges to open or grow the channel for this receive,
/// which the user approves before the invoice is created.
struct ReceivePrimaryConfirm: View {
    let amountSats: UInt64
    let onCreated: () -> Void

    @EnvironmentObject private var wallet: WalletViewModel

    @State private var quote: PrimaryReceiveQuote?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var maxFeeSats: UInt64 {
        ((quote?.feeMsat ?? 0) + 999) / 1000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("primary_receive__title"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                MoneyStack(sats: Int(amountSats))
                    .padding(.bottom, 32)

                if let quote {
                    CaptionMText(t("primary_receive__fee"))
                        .padding(.bottom, 8)
                    MoneyText(sats: Int(maxFeeSats), size: .bodySSB, testIdentifier: "PrimaryReceiveFee")
                        .padding(.bottom, 24)
                    CaptionMText(t("primary_receive__minimum"))
                        .padding(.bottom, 8)
                    MoneyText(sats: Int(amountSats - min(amountSats, maxFeeSats)), size: .bodySSB, testIdentifier: "PrimaryReceiveMin")
                        .padding(.bottom, 24)
                    if quote.fundingSats > 0 {
                        CaptionMText(t("primary_receive__capacity"))
                            .padding(.bottom, 8)
                        MoneyText(sats: Int(quote.fundingSats), size: .bodySSB, testIdentifier: "PrimaryReceiveCapacity")
                            .padding(.bottom, 24)
                    }
                    BodyMText(t("primary_receive__note"))
                }

                if let errorMessage {
                    BodyMText(errorMessage, textColor: .redAccent)
                        .accessibilityIdentifier("PrimaryReceiveError")
                }

                Spacer()

                HStack(spacing: 16) {
                    if errorMessage != nil {
                        CustomButton(title: t("common__retry"), variant: .secondary, isDisabled: isLoading) {
                            await requestQuote()
                        }
                        .accessibilityIdentifier("PrimaryReceiveRetry")
                    }
                    CustomButton(
                        title: t("primary_receive__create"),
                        isDisabled: quote == nil || isLoading,
                        isLoading: isLoading
                    ) {
                        await approve()
                    }
                    .accessibilityIdentifier("PrimaryReceiveApprove")
                }
            }
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
        .navigationBarHidden(true)
        .sheetBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PrimaryReceiveConfirm")
        .task {
            await requestQuote()
        }
    }

    private func requestQuote() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            quote = try await PrimaryNodeService.shared.quoteReceive(amountSats: amountSats)
        } catch {
            quote = nil
            errorMessage = error.primaryErrorMessage
        }
    }

    private func approve() async {
        guard let quote else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let bolt11 = try await PrimaryNodeService.shared.createInvoice(
                amountSats: amountSats,
                description: wallet.invoiceNote,
                maxFeeMsat: quote.feeMsat
            )
            try await wallet.setPrimaryReceiveInvoice(bolt11: bolt11, amountSats: amountSats)
            onCreated()
        } catch {
            self.quote = nil
            errorMessage = error.primaryErrorMessage
        }
    }
}
