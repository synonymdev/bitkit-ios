import BitkitCore
import SwiftUI

struct UsdtWalletScreen: View {
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @State private var showSend = false
    @State private var selectedTransferId: String?

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    UsdtAmountHeader(
                        amount: usdt.balance.map { usdtFormatAmount(amount: $0) } ?? "—",
                        network: usdt.networkName, hideBalance: settings.hideBalance
                    )
                    .balanceVisibilityToggle()
                    .accessibilityIdentifier("UsdtBalance")
                    HStack(spacing: 16) {
                        CustomButton(
                            title: t("usdt__receive"), variant: .secondary,
                            icon: Image("arrow-down").foregroundColor(.greenAccent), shouldExpand: true
                        ) { sheets.showSheet(.receive, data: ReceiveConfig(view: .usdt)) }
                            .accessibilityIdentifier("UsdtReceive")
                        CustomButton(
                            title: t("usdt__send"),
                            icon: Image("arrow-up").foregroundColor(.greenAccent), shouldExpand: true
                        ) { showSend = true }
                            .accessibilityIdentifier("UsdtSend")
                    }
                    if let error = usdt.errorMessage { BodySText(error, textColor: .brandAccent) }
                    activityList
                }
            }
            .contentMargins(.top, ScreenLayout.topPaddingWithoutSafeArea)
            .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
            .refreshable { await usdt.refresh(includeHistory: true) }
            NavigationBar(title: "USDT")
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .onReceive(usdt.receivedTxPublisher) { tx in
            guard !showSend, !sheets.isAnySheetOpen, !sheets.isReplacingSheet else { return }
            sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, usdtAmount: tx.amount))
        }
        .sheet(isPresented: $showSend) {
            Sheet(id: .send, data: SendSheetItem()) {
                UsdtSendView { id in
                    showSend = false
                    selectedTransferId = id
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedTransferId != nil },
            set: { if !$0 { selectedTransferId = nil } }
        )) {
            if let id = selectedTransferId { UsdtActivityDetail(transferId: id) }
        }
    }

    private var activityList: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if usdt.transfers.isEmpty {
                CaptionMText(t("usdt__activity"))
                RectangleButton(icon: "heartbeat", iconColor: .yellowAccent, title: t("usdt__empty"), testID: "UsdtEmptyActivity") {
                    sheets.showSheet(.receive, data: ReceiveConfig(view: .usdt))
                }
            }
            ForEach(Array(usdt.transfers.enumerated()), id: \.element.id) { index, transfer in
                let header = transfer.groupTitle
                if index == 0 || usdt.transfers[index - 1].groupTitle != header {
                    CaptionMText(header).frame(height: 34, alignment: .bottom)
                }
                Button { selectedTransferId = transfer.id } label: {
                    UsdtActivityRow(transfer: transfer, hideBalance: settings.hideBalance)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("UsdtActivity-\(index)")
            }
            if !usdt.historyComplete { BodySText(t("usdt__history_sync"), textColor: .textSecondary) }
        }
    }
}

struct UsdtAmountHeader: View {
    let amount: String
    let network: String
    var prefix = ""
    var hideBalance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CaptionMText("USDT · " + network, textColor: .textSecondary)
            DisplayText(
                "<accent>\(prefix)₮</accent> " + (hideBalance ? " • • • • •" : amount),
                accentColor: .textSecondary, accentFont: Fonts.extraBold
            )
            .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
extension UsdtDestination {
    var label: String {
        switch self {
        case .stable: "Stable"
        case .ethereum: "Ethereum"
        case .arbitrum: "Arbitrum One"
        case .polygon: "Polygon"
        case .plasma: "Plasma"
        case .base: "Base"
        case .bsc: "BNB Smart Chain"
        case .solana: "Solana"
        case .tron: "Tron"
        }
    }
}

extension UsdtTransferStatus {
    var label: String {
        switch self {
        case .pending: t("usdt__pending")
        case .confirmed: t("usdt__confirmed")
        case .failed: t("usdt__failed")
        case .bridging: t("usdt__bridging")
        case .bridgeNeedsAttention, .bridgeFailed: t("usdt__bridge_attention")
        case .replaced: t("usdt__replaced")
        case .bridgeRefunded: t("usdt__deposit_refunded")
        }
    }
}
