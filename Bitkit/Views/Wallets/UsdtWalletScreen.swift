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
            UsdtCoinIllustration()
                .scaleEffect(x: -1, y: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: 97, y: 4)
                .allowsHitTesting(false)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    UsdtAmountHeader(
                        amount: usdt.balance.map { usdtFormatAmount(amount: $0) } ?? "—",
                        displayAmount: usdt.balance.map { usdtOverviewAmount($0) }, hideBalance: settings.hideBalance
                    )
                    .balanceVisibilityToggle()
                    .accessibilityIdentifier("UsdtBalance")
                    if let error = usdt.errorMessage { BodySText(error, textColor: .brandAccent) }
                    activityList
                }
            }
            .contentMargins(.top, ScreenLayout.topPaddingWithoutSafeArea)
            .contentMargins(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
            .refreshable { await usdt.refresh(includeHistory: true) }
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: ScreenLayout.bottomPaddingWithSafeArea)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(spacing: 0) {
                    TabBarButton(title: t("wallet__send"), icon: "arrow-up", variant: .left) { showSend = true }
                        .accessibilityIdentifier("UsdtSend")
                    TabBarButton(title: t("wallet__receive"), icon: "arrow-down", variant: .right) {
                        sheets.showSheet(.receive, data: ReceiveConfig(view: .usdt))
                    }
                    .accessibilityIdentifier("UsdtReceive")
                }
                .overlay { ScanButton { sheets.showSheet(.scanner) } }
            }
            .bottomSafeAreaPadding()
            NavigationBar(title: "USDT", icon: "tether-circle")
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .onReceive(usdt.receivedTxPublisher) { tx in
            guard !showSend, !sheets.isAnySheetOpen, !sheets.isReplacingSheet else { return }
            sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, usdtAmount: tx.amount, usdtTransferId: tx.id))
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
            ForEach(Array(usdt.transfers.enumerated()), id: \.element.id) { index, transfer in
                let header = transfer.groupTitle
                if index == 0 || usdt.transfers[index - 1].groupTitle != header {
                    CaptionMText(header).padding(.top, index == 0 ? 0 : 16)
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

struct UsdtCoinIllustration: View {
    var body: some View {
        Image("tether-coin")
            .resizable().scaledToFill()
            .frame(width: 304.76, height: 228.57).clipped()
            .frame(width: 256, height: 256)
            .accessibilityHidden(true)
    }
}

struct UsdtAmountHeader: View {
    let amount: String
    var displayAmount: String?
    var prefix = ""
    var hideBalance = false

    @EnvironmentObject private var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let sats = usdtDisplaySats(amount: amount, rate: currency.paykitRate) {
                MoneyText(sats: sats, forceUnit: .bitcoin, size: .caption, symbol: true,
                          enableHide: hideBalance, color: .textSecondary)
            } else {
                CaptionMText("USDT", textColor: .textSecondary)
            }
            DisplayText(
                "<accent>\(prefix)$</accent> " + (hideBalance ? " • • • • •" : displayAmount ?? amount),
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

func usdtDisplaySats(amount: String, rate: PaykitExchangeRate?, now: Date = Date()) -> Int? {
    guard let dollars = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
          dollars >= 0, let price = try? rate?.value(at: now), price > 0 else { return nil }
    var value = dollars / price * 100_000_000
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 0, .down)
    guard rounded <= Decimal(Int.max) else { return nil }
    return NSDecimalNumber(decimal: rounded).intValue
}

func usdtOverviewAmount(_ amount: UInt64, locale: Locale = .current) -> String {
    let format = Decimal.FormatStyle.number.precision(.fractionLength(0 ... 2))
        .rounded(rule: .toNearestOrAwayFromZero).locale(locale)
    if amount > 0, amount < 10000 { return "<" + (Decimal(1) / 100).formatted(format) }
    return (Decimal(amount) / 1_000_000).formatted(format)
}
