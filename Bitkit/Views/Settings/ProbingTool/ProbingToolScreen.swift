import BitkitCore
import SwiftUI

struct ProbingToolScreen: View {
    @EnvironmentObject var app: AppViewModel

    @State private var invoice: String = ""
    @State private var amountSats: String = ""
    @State private var isLoading = false
    @State private var probeResult: ProbeResult?
    @State private var showScannerSheet = false
    @State private var isZeroAmountInvoice: Bool? = nil
    @State private var lastDecoded: (bolt11: String, amountSatoshis: UInt64)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Probing Tool",
                action: AnyView(Button(action: {
                    showScannerSheet = true
                }) {
                    Image("scan")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityIdentifier("ProbingToolScan"))
            )
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText("Probe Invoice")
                        TextField("lnbc...", text: $invoice, axis: .vertical)
                            .lineLimit(3 ... 6)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        CustomButton(title: "Paste", size: .small) {
                            pasteInvoice()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if isZeroAmountInvoice == true {
                            CaptionMText("Amount (required)")
                        } else {
                            CaptionMText("Amount (from invoice)")
                        }
                        TextField("Amount in sats", text: $amountSats)
                            .keyboardType(.numberPad)
                            .disabled(isZeroAmountInvoice == false)
                            .opacity(isZeroAmountInvoice == false ? 0.5 : 1)
                    }

                    CustomButton(title: "Send Probe", isDisabled: !canSendProbe, isLoading: isLoading) {
                        Task { await sendProbe() }
                    }

                    if let result = probeResult {
                        ProbeResultSectionView(result: result)
                    }
                }
            }
        }
        .task(id: invoice) {
            probeResult = nil
            await decodeInvoiceAndUpdateState()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showScannerSheet) {
            ProbingToolScannerSheet(invoice: $invoice) {
                showScannerSheet = false
            }
        }
    }

    private var canSendProbe: Bool {
        let input = invoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, lastDecoded != nil else { return false }
        if isZeroAmountInvoice == true {
            let value = UInt64(amountSats.filter(\.isNumber)) ?? 0
            return value >= 1
        }
        return true
    }

    /// Decodes the current invoice and updates lastDecoded, isZeroAmountInvoice, and amountSats.
    private func decodeInvoiceAndUpdateState() async {
        let trimmed = invoice.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = await decodeInvoice(trimmed)
        await MainActor.run {
            lastDecoded = decoded
            isZeroAmountInvoice = decoded.map { $0.amountSatoshis == 0 }
            if let decoded {
                amountSats = decoded.amountSatoshis > 0 ? "\(decoded.amountSatoshis)" : ""
            }
        }
    }

    /// Decodes input; returns bolt11 and invoice amount (0 if variable). Nil if not a valid lightning invoice.
    private func decodeInvoice(_ input: String) async -> (bolt11: String, amountSatoshis: UInt64)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let data = try await decode(invoice: trimmed)
            switch data {
            case let .onChain(onChainInvoice):
                guard let lnInvoice = onChainInvoice.params?["lightning"] else { return nil }
                if case let .lightning(invoice) = try? await decode(invoice: lnInvoice) {
                    return (lnInvoice, invoice.amountSatoshis)
                }
                return nil
            case let .lightning(invoice):
                return (trimmed, invoice.amountSatoshis)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private func pasteInvoice() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else {
            app.toast(type: .warning, title: "Clipboard is empty")
            return
        }
        invoice = pasted
    }

    private func sendProbe() async {
        let input = invoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            app.toast(type: .warning, title: "Please enter an invoice")
            return
        }

        await MainActor.run {
            isLoading = true
            probeResult = nil
        }

        let decoded = await MainActor.run { lastDecoded }
        guard let decoded else {
            await MainActor.run { isLoading = false }
            app.toast(
                type: .warning,
                title: "Invalid Invoice Format",
                description: "Could not extract Lightning invoice"
            )
            return
        }

        let amountSatsValue = UInt64(amountSats) ?? 0
        let lightningService = LightningService.shared
        let hasBalance = await MainActor.run { lightningService.canSend(amountSats: amountSatsValue) }
        guard hasBalance else {
            await MainActor.run { isLoading = false }
            app.toast(
                type: .warning,
                title: "Insufficient Balance",
                description: "More ₿ needed to probe this Lightning invoice."
            )
            return
        }

        let start = Date()

        do {
            try await lightningService.sendProbe(bolt11: decoded.bolt11, amountSats: amountSatsValue)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let estimatedFee: UInt64? = try? await lightningService.estimateRoutingFees(bolt11: decoded.bolt11, amountSats: amountSatsValue)
            await MainActor.run {
                probeResult = ProbeResult(
                    success: true,
                    durationMs: durationMs,
                    estimatedFeeSats: estimatedFee,
                    errorMessage: nil
                )
            }
            app.toast(type: .success, title: "Probe Successful", description: "Probe sent in \(durationMs) ms")
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            await MainActor.run {
                probeResult = ProbeResult(
                    success: false,
                    durationMs: durationMs,
                    estimatedFeeSats: nil,
                    errorMessage: error.localizedDescription
                )
            }
            app.toast(type: .error, title: "Probe Failed", description: error.localizedDescription)
        }

        await MainActor.run { isLoading = false }
    }
}
