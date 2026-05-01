import BitkitCore
import LDKNode
import SwiftUI

struct ProbingToolScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var invoice: String = ""
    @State private var amountSats: String = ""
    @State private var isLoading = false
    @State private var probeResult: ProbeResult?
    @State private var showScannerSheet = false
    @State private var isZeroAmountInvoice: Bool? = nil
    @State private var lastDecoded: (bolt11: String, amountSatoshis: UInt64)? = nil

    private enum ProbeTarget {
        case invoice(bolt11: String, amountSatoshis: UInt64)
        case nodeId(String)
    }

    private var isNodeIdTarget: Bool {
        if case .nodeId = probeTarget {
            return true
        }
        return false
    }

    private var isFixedAmountInvoice: Bool {
        !isNodeIdTarget && isZeroAmountInvoice == false
    }

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
                        CaptionMText("Probe Target")
                        TextField("Enter an invoice or node ID", text: $invoice, axis: .vertical)
                            .lineLimit(3 ... 6)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        CustomButton(title: "Paste", size: .small) {
                            pasteInvoice()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if isNodeIdTarget || isZeroAmountInvoice == true {
                            CaptionMText("Amount (required)")
                        } else if isFixedAmountInvoice {
                            CaptionMText("Amount (from invoice)")
                        } else {
                            CaptionMText("Amount")
                        }

                        TextField("Amount in sats", text: $amountSats)
                            .keyboardType(.numberPad)
                            .disabled(!isNodeIdTarget && isZeroAmountInvoice == false)
                            .opacity(!isNodeIdTarget && isZeroAmountInvoice == false ? 0.5 : 1)
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

        guard !input.isEmpty else { return false }
        if case .nodeId = probeTarget {
            let value = UInt64(amountSats.filter(\.isNumber)) ?? 0
            return value >= 1
        }

        guard lastDecoded != nil else { return false }
        if isZeroAmountInvoice == true {
            let value = UInt64(amountSats.filter(\.isNumber)) ?? 0
            return value >= 1
        }

        return true
    }

    private var probeTarget: ProbeTarget? {
        let input = invoice.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !input.isEmpty else { return nil }

        if isNodeId(input) {
            return .nodeId(input)
        }

        if let decoded = lastDecoded {
            return .invoice(bolt11: decoded.bolt11, amountSatoshis: decoded.amountSatoshis)
        }

        return nil
    }

    /// Decodes the current invoice and updates lastDecoded, isZeroAmountInvoice, and amountSats.
    private func decodeInvoiceAndUpdateState() async {
        let trimmed = invoice.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNodeId(trimmed) {
            await MainActor.run {
                lastDecoded = nil
                isZeroAmountInvoice = true
            }
            return
        }

        let decoded = await decodeInvoice(trimmed)
        await MainActor.run {
            lastDecoded = decoded
            isZeroAmountInvoice = decoded.map { $0.amountSatoshis == 0 }
            if let decoded {
                amountSats = decoded.amountSatoshis > 0 ? "\(decoded.amountSatoshis)" : ""
            }
        }
    }

    private func isNodeId(_ input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count == 66 else { return false }
        return cleaned.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdef").contains(scalar)
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
            app.toast(type: .warning, title: "Please enter an invoice or node ID")
            return
        }

        await MainActor.run {
            isLoading = true
            probeResult = nil
        }

        guard let target = await MainActor.run(body: { probeTarget }) else {
            await MainActor.run { isLoading = false }
            app.toast(
                type: .warning,
                title: "Invalid Target",
                description: "Enter a valid Lightning invoice or node ID"
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
            let dispatch: LightningService.ProbeDispatch = switch target {
            case let .invoice(bolt11, _):
                try await lightningService.sendProbe(bolt11: bolt11, amountSats: amountSatsValue)
            case let .nodeId(nodeId):
                try await lightningService.sendProbesSpontaneous(nodeId: nodeId, amountSats: amountSatsValue)
            }

            if dispatch.paymentIds.isEmpty {
                await MainActor.run { isLoading = false }
                app.toast(type: .error, title: "Probe Failed", description: "Probe was likely skipped (check logs)")
                return
            }

            let resolved = try await wallet.waitForProbeOutcome(paymentIds: dispatch.paymentIds)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)

            if resolved.success {
                let estimatedFee: UInt64? = switch target {
                case let .invoice(bolt11, _):
                    try? await lightningService.estimateRoutingFees(bolt11: bolt11, amountSats: amountSatsValue)
                case .nodeId:
                    nil
                }
                await MainActor.run {
                    probeResult = ProbeResult(
                        success: true,
                        durationMs: durationMs,
                        estimatedFeeSats: estimatedFee,
                        errorMessage: nil
                    )
                }
                app.toast(type: .success, title: "Probe Successful", description: "Route verified in \(durationMs) ms")
            } else {
                let scidText = resolved.shortChannelId.map(String.init) ?? "unknown"
                let message = "Hash: \(resolved.paymentHash), SCID: \(scidText)"
                await MainActor.run {
                    probeResult = ProbeResult(
                        success: false,
                        durationMs: durationMs,
                        estimatedFeeSats: nil,
                        errorMessage: message
                    )
                }
                app.toast(type: .error, title: "Probe Failed", description: message)
            }
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
