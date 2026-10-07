import BitkitCore
import SwiftUI

struct UsdtDepositHistoryView: View {
    let onBlockingChange: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var settings: SettingsViewModel
    @State private var deposits: [UsdtDeposit] = []
    @State private var nextOffset: UInt32?
    @State private var selected: UsdtDepositDetail?
    @State private var refundAddress = ""
    @State private var approved: RefundApproval?
    @State private var pageOffsets: [String: UInt32] = [:]
    @State private var confirmRefund = false
    @State private var pin = false
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?

    private var recoveryActive: Bool {
        confirmRefund || pin || approved != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let selected { detail(selected) }
                        else {
                            BodySText(t("usdt__deposit_status_note"), textColor: .textSecondary)
                            if deposits.isEmpty { BodySText(t("usdt__deposit_empty"), textColor: .textSecondary) }
                            ForEach(deposits, id: \.id) { deposit in
                                Button {
                                    Task { await loadDetail(deposit.id) }
                                } label: {
                                    ActivityRowContainer {
                                        ActivityRowContent(title: deposit.network.uppercased(), subtitle: deposit.statusText) {
                                            CircularIcon(
                                                icon: "arrow-down",
                                                iconColor: .greenAccent,
                                                backgroundColor: .greenAccent.opacity(0.16),
                                                size: 40
                                            )
                                        } amount: { BodySSBText(deposit.asset == "USDT" ? amount(deposit.amount) : deposit.asset) }
                                    }
                                }.buttonStyle(.plain).disabled(busy)
                            }
                            if let nextOffset {
                                CustomButton(title: t("usdt__deposit_more"), variant: .secondary, isDisabled: busy) { await loadPage(nextOffset) }
                            }
                        }
                        if let error { BodySText(error, textColor: .brandAccent) }
                        if let message { BodySText(message, textColor: .textSecondary) }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                CustomButton(title: t(selected == nil ? "usdt__deposit_refresh" : "usdt__deposit_history"),
                             variant: .secondary, isDisabled: busy, isLoading: busy)
                {
                    selected = nil
                    message = nil
                    refundAddress = ""
                    approved = nil
                    await loadPage(0)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $pin) {
                SendPinScreen(onCancel: {
                    pin = false
                    approved = nil
                }, onPinVerified: {
                    pin = false
                    Task { await refund() }
                })
            }
            .alert(t("usdt__deposit_refund"), isPresented: $confirmRefund) {
                Button(t("common__cancel"), role: .cancel) {}
                Button(t("usdt__deposit_refund")) {
                    if let deposit = selected?.deposit {
                        approved = RefundApproval(deposit: deposit, offset: pageOffsets[deposit.id] ?? 0, address: refundAddress)
                        Task { await authorizeRefund() }
                    }
                }
            } message: {
                Text((selected?.deposit.network.uppercased() ?? "") + "\n" + (selected?.deposit.id ?? "") + "\n" + amount(selected?.deposit.amount) +
                    "\n" + refundAddress + "\n\n" + t("usdt__deposit_refund_note"))
            }
        }
        .task { await loadPage(0) }
        .task(id: "\(scenePhase == .active)-\(selected?.deposit.id ?? "")-\(recoveryActive)") {
            guard scenePhase == .active, !recoveryActive, let id = selected?.deposit.id else { return }
            while !Task.isCancelled {
                if let selected, ["completed", "refunded"].contains(selected.order?.status ?? selected.deposit.status) { return }
                do {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation()
                } catch { return }
                guard !recoveryActive else { return }
                await loadDetail(id)
            }
        }
        .interactiveDismissDisabled(busy || pin)
        .onChange(of: busy || pin) { _, blocked in onBlockingChange(blocked) }
        .onDisappear { onBlockingChange(false) }
    }

    private func detail(_ detail: UsdtDepositDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if detail.deposit.asset == "USDT" {
                UsdtAmountHeader(amount: detail.deposit.amount.map { usdtFormatAmount(amount: $0) } ?? "—",
                                 network: detail.deposit.network.uppercased(), hideBalance: settings.hideBalance)
            } else {
                BodySSBText(detail.deposit.asset + " · " + detail.deposit.network.uppercased())
            }
            SendSectionView(t("wallet__activity_status")) { BodySSBText(detail.statusText) }
            BodySText(t("usdt__deposit_status_note"), textColor: .textSecondary)
            SendSectionView(t("usdt__deposit_reference")) { BodySText(detail.deposit.id).textSelection(.enabled) }
            SendSectionView(t("wallet__activity_tx_id")) { BodySText(detail.deposit.sourceTx).textSelection(.enabled) }
            if let code = detail.statusCode { BodySText(code, textColor: .textSecondary).textSelection(.enabled) }
            if let order = detail.order, order.status != "refunded", let received = order.amountOut {
                SendSectionView(t("usdt__deposit_batch")) { BodySSBText(amount(received)) }
                if let sent = order.amountIn, sent >= received {
                    SendSectionView(t("usdt__deposit_cost")) { BodySSBText(amount(sent - received)) }
                }
            }
            if let tx = detail.order?
                .destinationTx { SendSectionView(t("wallet__activity_tx_id") + " · Arbitrum One") { BodySText(tx).textSelection(.enabled) } }
            if let tx = detail.order?.refundTx ?? detail.deposit.refundTx {
                SendSectionView(t("usdt__deposit_refund")) { BodySText(tx).textSelection(.enabled) }
            }
            if detail.deposit.asset != "USDT" || UsdtDepositNetwork.named(detail.deposit.network) == nil {
                BodySText(t("usdt__deposit_wrong_asset"), textColor: .textSecondary)
            } else if !["completed", "refunded", "refunding", "refund_requested"].contains(detail.order?.status ?? detail.deposit.status) {
                BodySText(t("usdt__deposit_refund_note"), textColor: .textSecondary)
                TextField(t("usdt__deposit_refund_address"), text: $refundAddress, axis: .vertical, testIdentifier: "UsdtRefundAddress")
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                CustomButton(title: t("usdt__deposit_refund"), variant: .secondary,
                             isDisabled: busy || refundAddress.isEmpty, isLoading: busy) { if !busy { confirmRefund = true } }
                    .accessibilityIdentifier("UsdtDepositRefund")
            }
            UsdtSupportActions(details: detail.supportDetails).disabled(busy || recoveryActive)
        }
    }

    private func amount(_ value: UInt64?) -> String {
        (settings.hideBalance ? " • • • • •" : value.map { usdtFormatAmount(amount: $0) } ?? "—") + " USDT"
    }

    private func loadPage(_ offset: UInt32) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let page = try await usdt.depositHistory(offset: offset)
            if offset == 0 {
                deposits = []
                pageOffsets = [:]
            }
            for deposit in page.deposits {
                deposits.removeAll { $0.id == deposit.id }
                deposits.append(deposit)
                pageOffsets[deposit.id] = offset
            }
            nextOffset = page.nextOffset
        } catch is CancellationError {} catch { self.error = UsdtWalletManager.message(for: error) }
    }

    private func loadDetail(_ id: String) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let detail = try await usdt.depositDetail(id: id, offset: pageOffsets[id] ?? 0)
            if selected?.deposit.id != id {
                refundAddress = ""
                approved = nil
                message = nil
            }
            selected = detail
        } catch is CancellationError {} catch { self.error = UsdtWalletManager.message(for: error) }
    }

    private func authorizeRefund() async {
        guard !busy else { return }
        defer { if !pin { approved = nil } }
        if settings.requirePinForPayments && settings.pinEnabled {
            guard settings.useBiometrics && BiometricAuth.isAvailable else {
                pin = true
                return
            }
            busy = true
            let result = await BiometricAuth.authenticate()
            busy = false
            switch result {
            case .success: await refund()
            case .cancelled: break
            case let .failed(message): error = message
            }
        } else { await refund() }
    }

    private func refund() async {
        guard !busy, let selected, let approved, selected.deposit.id == approved.deposit.id else { return }
        busy = true
        error = nil
        defer {
            busy = false
            self.approved = nil
        }
        do {
            try await usdt.refundDeposit(approved.deposit, offset: approved.offset, address: approved.address)
            var acknowledged = selected
            acknowledged.deposit.status = "refund_requested"
            acknowledged.deposit.code = nil
            acknowledged.order?.status = "refund_requested"
            acknowledged.order?.code = nil
            self.selected = acknowledged
            message = t("usdt__deposit_refund_requested")
        } catch { self.error = UsdtWalletManager.message(for: error) }
    }
}

private struct RefundApproval {
    let deposit: UsdtDeposit
    let offset: UInt32
    let address: String
}

extension UsdtDeposit {
    var statusText: String {
        code == nil ? depositStatusText(status) : t("usdt__deposit_needs_attention")
    }
}

extension UsdtDepositDetail {
    var statusCode: String? {
        if let order { return order.code }
        return deposit.code
    }

    var statusText: String {
        statusCode == nil ? depositStatusText(order?.status ?? deposit.status) : t("usdt__deposit_needs_attention")
    }
}

private func depositStatusText(_ status: String) -> String {
    switch status {
    case "completed": t("usdt__confirmed")
    case "refunded": t("usdt__deposit_refunded")
    case "refunding", "refund_requested": t("usdt__deposit_refunding")
    case "pending", "processing": t("usdt__pending")
    default: t("usdt__deposit_needs_attention")
    }
}
