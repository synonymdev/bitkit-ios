import BitkitCore
import SwiftUI

struct UsdtDepositHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var settings: SettingsViewModel
    @State private var deposits: [UsdtDeposit] = []
    @State private var nextOffset: UInt32?
    @State private var selected: UsdtDepositDetail?
    @State private var refundAddress = ""
    @State private var showDetails = false
    @State private var approved: RefundApproval?
    @State private var pageOffsets: [String: UInt32] = [:]
    @State private var confirmRefund = false
    @State private var pin = false
    @State private var busy = false
    @State private var error: String?
    @State private var refundError: String?
    @State private var message: String?

    private var recoveryActive: Bool {
        confirmRefund || pin || approved != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: selected == nil ? t("usdt__deposit_history") : t("usdt__receiving_title"),
                titleKerning: 0,
                titleLineHeight: 26,
                onBack: {
                    if selected == nil {
                        dismiss()
                    } else {
                        clearSelection()
                    }
                }
            )
            .disabled(busy || recoveryActive)
            .padding(.bottom, 16)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let selected {
                        detail(selected)
                    } else {
                        depositList
                    }
                    if let error {
                        BodySText(error, textColor: .brandAccent).accessibilityIdentifier("UsdtDepositError")
                    }
                    if let message {
                        BodySText(message, textColor: .textSecondary)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                guard !recoveryActive else { return }
                if let selected {
                    await loadDetail(selected.deposit.id)
                } else {
                    await loadPage(0)
                }
            }
            if selected != nil {
                CustomButton(title: t("usdt__deposit_history"), isDisabled: busy || recoveryActive, titleKerning: -0.4, titleLineHeight: 20) {
                    clearSelection()
                    await loadPage(0)
                }
                .padding(.top, 16)
                .accessibilityIdentifier("UsdtDepositHistory")
            } else if error != nil || deposits.isEmpty {
                CustomButton(title: t("usdt__deposit_refresh"), isDisabled: busy, isLoading: busy) { await loadPage(0) }
            }
        }
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .background(Color.black)
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
        .alert(t("usdt__deposit_confirm_refund"), isPresented: $confirmRefund) {
            Button(t("common__cancel"), role: .cancel) {}
                .accessibilityIdentifier("UsdtRefundCancel")
            Button(t("usdt__deposit_refund")) {
                if let detail = selected, detail.canRequestRefund {
                    let deposit = detail.deposit
                    approved = RefundApproval(deposit: deposit, offset: pageOffsets[deposit.id] ?? 0, address: refundAddress)
                    Task { await authorizeRefund() }
                }
            }
            .accessibilityIdentifier("UsdtRefundConfirm")
        } message: {
            Text(selected?.refundConfirmation(address: refundAddress, hideBalance: settings.hideBalance) ?? "")
        }
        .task {
            if !recoveryActive {
                await loadPage(0)
            }
        }
        .task(id: "\(scenePhase == .active)-\(selected?.deposit.id ?? "")-\(recoveryActive)") {
            guard scenePhase == .active, !recoveryActive, let id = selected?.deposit.id else { return }
            while !Task.isCancelled {
                if let selected, ["completed", "refunded"].contains(selected.order?.status ?? selected.deposit.status) {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation()
                } catch { return }
                guard !recoveryActive else { return }
                await loadDetail(id, isRefreshing: true)
            }
        }
        .onChange(of: refundAddress) { _, _ in refundError = nil }
        .interactiveDismissDisabled(busy || pin)
    }

    private var depositList: some View {
        VStack(alignment: .leading, spacing: 16) {
            SendSectionView(t("usdt__provider_status"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                BodySSBText(t("usdt__deposit_status_note"), kerning: 0, lineHeight: 20)
            }
            if deposits.isEmpty, !busy {
                BodySText(t("usdt__deposit_empty"), textColor: .textSecondary)
            }
            ForEach(deposits, id: \.id) { deposit in
                Button { Task { await loadDetail(deposit.id) } } label: {
                    UsdtDepositRow(deposit: deposit, hideBalance: settings.hideBalance)
                }
                .buttonStyle(.plain).disabled(busy)
                .accessibilityIdentifier("UsdtDepositRow-\(deposit.id)")
            }
            if let nextOffset {
                CustomButton(title: t("usdt__deposit_more"), variant: .secondary, isDisabled: busy) { await loadPage(nextOffset) }
            }
        }
    }

    private func detail(_ detail: UsdtDepositDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if detail.deposit.asset == "USDT" {
                UsdtActivityAmountHeader(amount: detail.deposit.amount, isIncoming: true, hideBalance: settings.hideBalance)
                    .padding(.bottom, 16)
            } else {
                BodySSBText(detail.deposit.asset + " · " + detail.deposit.networkLabel, lineHeight: 20)
            }
            if showDetails {
                SendSectionView(t("wallet__activity_tx_id"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                    BodySSBText(detail.deposit.sourceTx, kerning: 0, lineHeight: 20).textSelection(.enabled)
                }
                SendSectionView(t("usdt__deposit_reference"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                    BodySSBText(detail.deposit.id, kerning: 0, lineHeight: 20).textSelection(.enabled)
                }
                if !detail.canRequestRefund {
                    UsdtDetailCell(title: t("wallet__activity_status"), value: detail.statusText, icon: detail.statusIcon,
                                   valueColor: detail.statusColor, iconColor: detail.statusColor, valueKerning: 0)
                }
                if detail.canRequestRefund {
                    SendSectionView(t("usdt__deposit_refund_heading"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                        BodySSBText(
                            t("usdt__deposit_refund_instructions", variables: ["network": detail.deposit.refundNetworkLabel]),
                            kerning: 0,
                            lineHeight: 20
                        )
                    }
                    TextField(t("usdt__deposit_refund_address_network", variables: ["network": detail.deposit.refundNetworkLabel]),
                              text: $refundAddress, axis: .vertical, testIdentifier: "UsdtRefundAddress", placeholderColor: .white50,
                              minContentHeight: 20)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                        .environment(\._lineHeightMultiple, 20 / (UIFont(name: Fonts.semiBold, size: 15)?.lineHeight ?? 20))
                    if let refundError {
                        BodySText(refundError, textColor: .brandAccent).accessibilityIdentifier("UsdtRefundError")
                    }
                }
                let buttonLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 16))
                    : AnyLayout(HStackLayout(spacing: 16))
                buttonLayout {
                    if detail.canRequestRefund {
                        CustomButton(title: t("usdt__deposit_refund_action"), size: .small,
                                     icon: Image("coins").resizable().frame(width: 16, height: 16).foregroundColor(.usdtAccent),
                                     isDisabled: busy || refundAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                     isLoading: busy, shouldExpand: true, titleKerning: 0, titleLineHeight: 13) { confirmRefund = true }
                            .accessibilityIdentifier("UsdtDepositRefund")
                    }
                    detailsButton
                }
                if detail.canRequestRefund, UsdtDepositNetwork.named(detail.deposit.network) == .tron {
                    BodySText(t("usdt__deposit_tron_refund_note"), textColor: .textSecondary)
                }
                if detail.statusText == t("usdt__deposit_needs_attention") {
                    BodySText(t("usdt__deposit_attention"), textColor: .textSecondary)
                }
                if let tx = detail.order?.destinationTx {
                    SendSectionView(t("usdt__destination_tx"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                        BodySSBText(tx, kerning: 0, lineHeight: 20).textSelection(.enabled)
                    }
                }
                if let tx = detail.order?.refundTx ?? detail.deposit.refundTx {
                    SendSectionView(t("usdt__refund_tx"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                        BodySSBText(tx, kerning: 0, lineHeight: 20).textSelection(.enabled)
                    }
                }
                if detail.deposit.asset != "USDT" || UsdtDepositNetwork.named(detail.deposit.network) == nil {
                    BodySText(t("usdt__deposit_wrong_asset"), textColor: .textSecondary)
                }
                UsdtSupportActions(details: detail.supportDetails).disabled(busy || recoveryActive)
            } else {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    UsdtDetailCell(title: t("wallet__activity_status"), value: detail.statusText, icon: detail.statusIcon,
                                   valueColor: detail.statusColor, iconColor: detail.statusColor, valueKerning: 0)
                    UsdtDetailCell(title: t("usdt__receiving_network"), value: UsdtDestination.arbitrum.label, icon: "usdt-network")
                }
                UsdtDetailCell(title: t("usdt__sender_network"), value: detail.deposit.networkLabel, icon: "usdt-network")
                if let order = detail.order, order.status != "refunded", let received = order.amountOut {
                    SendSectionView(t("usdt__deposit_batch"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) { BodySSBText(
                        amount(received),
                        lineHeight: 20
                    ) }
                    if let sent = order.amountIn, sent >= received {
                        SendSectionView(t("usdt__deposit_cost"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) { BodySSBText(
                            amount(sent - received),
                            lineHeight: 20
                        ) }
                    }
                }
                detailsButton
                UsdtSupportActions(details: detail.supportDetails).disabled(busy || recoveryActive)
            }
        }
    }

    private var detailsButton: some View {
        CustomButton(title: t(showDetails ? "usdt__hide_details" : "wallet__send_details"), size: .small,
                     icon: Image(showDetails ? "eye-slash" : "git-branch").resizable().frame(width: 16, height: 16)
                         .foregroundColor(.usdtAccent), isDisabled: busy || recoveryActive, shouldExpand: true, titleKerning: 0,
                     titleLineHeight: 13)
        {
            showDetails.toggle()
        }
        .accessibilityIdentifier("UsdtDepositDetails")
    }

    private func clearSelection() {
        selected = nil
        message = nil
        error = nil
        refundAddress = ""
        refundError = nil
        approved = nil
        showDetails = false
    }

    private func amount(_ value: UInt64?) -> String {
        (settings.hideBalance ? " • • • • •" : value.map { usdtOverviewAmount($0) } ?? "—") + " USDT"
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

    private func loadDetail(_ id: String, isRefreshing: Bool = false) async {
        guard !busy else { return }
        let previous = selected
        guard !isRefreshing || previous?.deposit.id == id else { return }
        if !isRefreshing {
            busy = true
            error = nil
        }
        defer {
            if !isRefreshing {
                busy = false
            }
        }
        do {
            let detail = try await usdt.depositDetail(id: id, offset: pageOffsets[id] ?? 0)
            try Task.checkCancellation()
            guard !isRefreshing || (!busy && !recoveryActive && selected == previous) else { return }
            error = nil
            if selected?.deposit.id != id {
                refundAddress = ""
                refundError = nil
                approved = nil
                message = nil
                showDetails = false
            }
            if ["completed", "refunded"].contains(detail.order?.status ?? detail.deposit.status) {
                message = nil
            }
            updateSelection(detail)
        } catch is CancellationError {} catch {
            guard !isRefreshing || (!busy && !recoveryActive && selected == previous) else { return }
            self.error = UsdtWalletManager.message(for: error)
        }
    }

    private func updateSelection(_ detail: UsdtDepositDetail) {
        selected = detail
        if let index = deposits.firstIndex(where: { $0.id == detail.deposit.id }) {
            deposits[index].status = detail.order?.status ?? detail.deposit.status
            deposits[index].code = detail.statusCode
            deposits[index].refundTx = detail.order?.refundTx ?? detail.deposit.refundTx
        }
    }

    private func authorizeRefund() async {
        guard !busy else { return }
        defer {
            if !pin {
                approved = nil
            }
        }
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
            case let .failed(message): refundError = message
            }
        } else {
            await refund()
        }
    }

    private func refund() async {
        guard !busy, let selected, let approved, selected.deposit.id == approved.deposit.id else { return }
        busy = true
        refundError = nil
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
            updateSelection(acknowledged)
            message = t("usdt__deposit_refund_requested")
        } catch { refundError = UsdtWalletManager.message(for: error) }
    }
}

private struct RefundApproval {
    let deposit: UsdtDeposit
    let offset: UInt32
    let address: String
}

extension UsdtDepositDetail {
    var canRequestRefund: Bool {
        deposit.asset == "USDT" && UsdtDepositNetwork.named(deposit.network) != nil &&
            !["completed", "refunded", "refunding", "refund_requested"].contains(order?.status ?? deposit.status)
    }

    var statusIcon: String {
        ["completed", "refunded"].contains(order?.status ?? deposit.status) ? "check-circle" : "hourglass-simple"
    }

    var statusColor: Color {
        ["completed", "refunded"].contains(order?.status ?? deposit.status) ? .usdtAccent : .yellowAccent
    }

    func refundConfirmation(address: String, hideBalance: Bool, locale: Locale = .current) -> String {
        t("usdt__deposit_refund_confirmation", variables: [
            "amount": hideBalance ? "• • • • •" : deposit.amount.map { usdtExactAmount($0, locale: locale) } ?? "—",
            "network": UsdtDepositNetwork.named(deposit.network) == .bsc ? "BNB Smart Chain (BSC)" : deposit.networkLabel,
            "shortNetwork": deposit.refundNetworkLabel,
            "address": address,
        ])
    }

    var statusCode: String? {
        if let order {
            return order.code
        }
        return deposit.code
    }

    var statusText: String {
        depositStatusText(order?.status ?? deposit.status, code: statusCode)
    }
}

private func depositStatusText(_ status: String, code: String?) -> String {
    switch status {
    case "completed": t("usdt__confirmed")
    case "refunded": t("usdt__deposit_refunded")
    case "refunding", "refund_requested":
        code == nil || code == "standing_refund_pending" ? t("usdt__deposit_refunding") : t("usdt__deposit_needs_attention")
    case "pending", "processing", "funded", "confirming", "swapping", "bridging", "delivering":
        code == nil ? t("usdt__pending") : t("usdt__deposit_needs_attention")
    default: t("usdt__deposit_needs_attention")
    }
}

extension UsdtDeposit {
    var networkLabel: String {
        UsdtDepositNetwork.named(network)?.label ?? network
    }

    var refundNetworkLabel: String {
        UsdtDepositNetwork.named(network) == .bsc ? "BSC" : networkLabel
    }

    var statusText: String {
        depositStatusText(status, code: code)
    }
}

struct UsdtDepositRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let deposit: UsdtDeposit
    let hideBalance: Bool

    private var amount: String {
        hideBalance ? "• • • • •" : deposit.amount.map { usdtOverviewAmount($0) } ?? "—"
    }

    var body: some View {
        let completed = ["completed", "refunded"].contains(deposit.status)
        let color: Color = completed ? .usdtAccent : .yellowAccent
        ActivityRowContainer {
            ActivityRowContent(title: deposit.networkLabel, subtitle: deposit.statusText, textKerning: 0,
                               titleLineHeight: 22, subtitleLineHeight: 18, textSpacing: 0, stacked: dynamicTypeSize.isAccessibilitySize)
            {
                CircularIcon(icon: completed ? "check-circle" : "hourglass-simple", iconColor: color,
                             backgroundColor: color.opacity(0.16), size: 40)
            } amount: {
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
                    BodyMSBText(deposit.asset == "USDT" ? amount + " USDT" : deposit.asset, kerning: 0, lineHeight: 22)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                    if deposit.asset == "USDT" {
                        CaptionBText(hideBalance ? amount : "$" + amount, textColor: .textSecondary, kerning: 0, lineHeight: 18)
                    }
                }
            }
        }
    }
}
