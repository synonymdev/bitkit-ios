import SwiftUI

struct SendFundingSourceButton: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    private var usdt: UsdtWalletManager {
        wallet.usdtWallet
    }

    @Environment(HwWalletManager.self) private var hwWalletManager

    let hwSend: HwSendCoordinator
    var disabled = false
    var allowsUsdt = true
    let onSelect: (SendFundingSource) -> Void
    @State private var showingFundingSources = false

    private var fundingSources: [SendFundingSource] {
        if let request = app.contactPaymentContext?.incomingPaymentRequest,
           PaykitUsdtPaymentService.shared.hasBinding(for: request.id)
        {
            return [.usdt]
        }
        var sources: [SendFundingSource] = []
        if app.scannedLightningInvoice != nil || app.lnurlPayData != nil {
            sources.append(.spending)
        }
        if app.scannedOnchainInvoice != nil {
            sources.append(.savings)
            sources.append(contentsOf: hwWalletManager.wallets.compactMap { hardwareWallet in
                guard hardwareWallet.fundingBalanceSats > 0 || hardwareWallet.walletId == hwSend.walletId else {
                    return nil
                }
                return .hardware(walletId: hardwareWallet.walletId)
            })
        }
        if allowsUsdt, settings.isUsdtEnabled,
           app.contactPaymentContext?.endpoints.contains(where: { $0.methodId == .usdtArbitrum }) == true
        {
            sources.append(.usdt)
        }
        return sources
    }

    private var selectedFundingSource: SendFundingSource {
        if app.paykitUsesUsdt {
            return .usdt
        }
        if let walletId = hwSend.walletId {
            return .hardware(walletId: walletId)
        }
        return app.selectedWalletToPayFrom == .lightning ? .spending : .savings
    }

    private var canSwitchFundingSource: Bool {
        fundingSources.count > 1
    }

    private var selectedSourceLabel: String {
        fundingSourceLabel(selectedFundingSource)
    }

    private var selectedSourceColor: Color {
        fundingSourceColor(selectedFundingSource)
    }

    private var assetButtonTestIdentifier: String {
        if canSwitchFundingSource {
            return "switch"
        }
        return switch selectedFundingSource {
        case .spending: "spending"
        case .savings: "savings"
        case .usdt: "usdt"
        case .hardware: "trezor"
        }
    }

    var body: some View {
        NumberPadActionButton(
            text: selectedSourceLabel,
            trailingImageName: canSwitchFundingSource ? "chevron-down" : nil,
            titleKerning: app.paykitUsesUsdt ? 1 : 0.8,
            titleLineHeight: app.paykitUsesUsdt ? 18 : nil,
            color: selectedSourceColor,
            variant: .secondary,
            disabled: disabled,
            isLoading: hwSend.isFundingSourceLoading
        ) {
            showingFundingSources = true
        }
        .accessibilityIdentifier("AssetButton-\(assetButtonTestIdentifier)")
        .popover(isPresented: $showingFundingSources, arrowEdge: .bottom) {
            fundingSourceMenu
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Color.gray6)
        }
    }

    private var fundingSourceMenu: some View {
        let sources: [SendFundingSource] = [.savings, .spending] + hwWalletManager.wallets.map {
            .hardware(walletId: $0.walletId)
        } + (allowsUsdt && (settings.isUsdtEnabled || app.paykitUsesUsdt) ? [.usdt] : [])
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(sources.indices, id: \.self) { index in
                let source = sources[index]
                let enabled = fundingSources.contains(source)
                Button {
                    showingFundingSources = false
                    if source != selectedFundingSource {
                        onSelect(source)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            CaptionMText(fundingSourceLabel(source), kerning: 1, lineHeight: 18).lineLimit(1)
                            if case let .hardware(walletId) = source,
                               let hardwareWallet = hwWalletManager.wallets.first(where: { $0.walletId == walletId })
                            {
                                HwWalletConnectionIcon(isConnected: hardwareWallet.isConnected)
                                    .frame(width: 16, height: 16)
                            }
                        }
                        HStack(spacing: 8) {
                            Image(fundingSourceIcon(source)).resizable().scaledToFit().frame(width: 24, height: 24)
                            if source == .usdt {
                                BodyMSBText(settings.hideBalance ? "•••••" : usdt.balance.map { usdtOverviewAmount($0) } ?? "—",
                                            kerning: 0, lineHeight: 22)
                            } else {
                                MoneyText(sats: Int(fundingSourceBalance(source)), forceUnit: .bitcoin, size: .bodyMSB,
                                          symbol: false, enableHide: true, fillsWidth: false, kerning: 0, lineHeight: 22)
                            }
                            Spacer(minLength: 0)
                            if source == selectedFundingSource {
                                Image("check-mark").resizable().scaledToFit().frame(width: 16, height: 16)
                                    .foregroundStyle(fundingSourceColor(source))
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NoAnimationButtonStyle())
                .disabled(!enabled || hwSend.isFundingSourceLoading)
                .opacity(enabled ? 1 : 0.30)
                .accessibilityIdentifier("SendFundingSource-\(index)")
                if index < sources.count - 1 {
                    CustomDivider()
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(width: 250)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SendFundingSources")
    }

    private func fundingSourceLabel(_ source: SendFundingSource) -> String {
        switch source {
        case .savings: t("wallet__savings__title")
        case .spending: t("wallet__spending__title")
        case .usdt: "USDT"
        case let .hardware(walletId):
            hwWalletManager.wallets.first { $0.walletId == walletId }?.name ?? hwWalletManager.vendor(walletId: walletId).modelName
        }
    }

    private func fundingSourceColor(_ source: SendFundingSource) -> Color {
        switch source {
        case .savings: .brandAccent
        case .spending: .purpleAccent
        case .usdt: .usdtAccent
        case .hardware: .blueAccent
        }
    }

    private func fundingSourceIcon(_ source: SendFundingSource) -> String {
        switch source {
        case .savings: "btc"
        case .spending: "ln"
        case .usdt: "tether-circle"
        case .hardware: "btc-circle-blue"
        }
    }

    private func fundingSourceBalance(_ source: SendFundingSource) -> UInt64 {
        switch source {
        case .savings: UInt64(wallet.spendableOnchainBalanceSats)
        case .spending: UInt64(wallet.maxSendLightningSats)
        case let .hardware(walletId): hwWalletManager.fundingBalance(walletId: walletId)
        case .usdt: 0
        }
    }
}
