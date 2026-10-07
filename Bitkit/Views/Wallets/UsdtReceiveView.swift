import BitkitCore
import SwiftUI

struct UsdtReceiveView: View {
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var networks: [UsdtDepositNetwork] = []
    @State private var network: UsdtDepositNetwork?
    @State private var history = false
    @State private var historyBlocking = false
    @State private var unavailable = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t(history ? "usdt__deposit_history" : "usdt__receive_title"), showBackButton: true,
                        onBack: { if history { history = false } else { dismiss() } })
                .disabled(historyBlocking)
            if history {
                UsdtDepositHistoryView(onBlockingChange: { historyBlocking = $0 })
            } else {
                HStack {
                    Menu {
                        Button("Arbitrum One") { network = nil }
                        ForEach(networks, id: \.self) { item in Button(item.label) { network = item } }
                    } label: {
                        NumberPadActionButton(text: network?.label ?? "Arbitrum One", color: .greenAccent, variant: .secondary) {}
                    }
                    .accessibilityIdentifier("UsdtReceiveNetwork")
                    Spacer()
                    if usdt.depositsConfigured {
                        Button { history = true } label: { BodySSBText(t("usdt__activity"), textColor: .greenAccent) }
                            .accessibilityIdentifier("UsdtDepositHistory")
                    }
                }.padding(.bottom, 16)
                if let network { UsdtDepositReceiveView(network: network).id(network) }
                else {
                    if unavailable { BodySText(t("usdt__deposit_unavailable"), textColor: .textSecondary).padding(.bottom, 12) }
                    UsdtReceiveAddressContent(
                        address: usdt.address,
                        uri: usdt.receiveUri,
                        warning: t("usdt__receive_warning"),
                        error: usdt.errorMessage
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .onReceive(usdt.receivedTxPublisher) { transfer in
            guard !historyBlocking, sheets.activeSheetConfiguration?.id == .receive else { return }
            sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, usdtAmount: transfer.amount))
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await usdt.refresh(includeHistory: true)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task {
            do { networks = try await usdt.depositNetworks() }
            catch is CancellationError {} catch { unavailable = true }
        }
    }
}

struct UsdtReceiveAddressContent<Details: View>: View {
    let address: String
    let uri: String
    let warning: String
    var error: String?
    @ViewBuilder var details: () -> Details
    @State private var showDetails = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if !uri.isEmpty {
                    if showDetails {
                        CopyAddressCard(addresses: [CopyAddressPair(title: t("usdt__receive_title"), address: address, type: .onchain)],
                                        navigationPath: .constant([]), editRoute: nil, accentColor: .greenAccent)
                    } else {
                        QrArea(uri: uri, imageAsset: nil, accentColor: .greenAccent, navigationPath: .constant([]),
                               copyValue: address, editRoute: nil)
                    }
                    BodySText(address, textColor: .textSecondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityIdentifier("UsdtReceiveAddress")
                } else if let error { BodySText(error, textColor: .brandAccent) }
                else { ProgressView() }
                details()
                BodySText(warning, textColor: .textSecondary)
            }
        }
        CustomButton(title: t(showDetails ? "wallet__receive_show_qr" : "common__show_details"),
                     variant: showDetails ? .primary : .tertiary,
                     icon: showDetails ? Image("qr").resizable().frame(width: 16, height: 16) : nil, shouldExpand: true)
        {
            showDetails.toggle()
        }.accessibilityIdentifier("UsdtReceiveDetails")
    }
}

extension UsdtReceiveAddressContent where Details == EmptyView {
    init(address: String, uri: String, warning: String, error: String? = nil) {
        self.address = address; self.uri = uri; self.warning = warning; self.error = error; details = { EmptyView() }
    }
}

private struct UsdtDepositReceiveView: View {
    let network: UsdtDepositNetwork
    @Environment(UsdtWalletManager.self) private var usdt
    @State private var amount = ""
    @State private var deposit: UsdtDepositAddress?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if let deposit {
            UsdtReceiveAddressContent(address: deposit.address, uri: deposit.uri, warning: t("usdt__deposit_notice")) {
                SendSectionView(t("usdt__deposit_estimate")) { BodySSBText(usdtFormatAmount(amount: deposit.estimatedReceived) + " USDT") }
                SendSectionView(t("usdt__deposit_cost")) {
                    BodySSBText(deposit.amount >= deposit
                        .estimatedReceived ? usdtFormatAmount(amount: deposit.amount - deposit.estimatedReceived) + " USDT" : "—")
                }
                BodySText(t("usdt__deposit_estimate_note"), textColor: .textSecondary)
                SendSectionView(t("usdt__deposit_limits")) {
                    BodySSBText((deposit.minUsdCents?.usdCents ?? "—") + " – " + (deposit.maxUsdCents?.usdCents ?? "—"))
                }
                BodySText(t("usdt__deposit_limits_note"), textColor: .textSecondary)
                CustomButton(title: t("usdt__deposit_refresh"), variant: .secondary, shouldExpand: true) { self.deposit = nil }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("usdt__deposit_amount")).padding(.bottom, 12)
                NumberPadAmountText(value: amount.isEmpty ? "0" : amount, symbol: "₮")
                Spacer(minLength: 16)
                BodySText(error ?? t("usdt__deposit_fee_note"), textColor: error == nil ? .textSecondary : .brandAccent)
                    .padding(.bottom, 16)
                Divider()
                NumberPad(type: .decimal, isDisabled: busy, onDeleteLongPress: { amount = "" }) { key in
                    amount = NumberPadInputHandler.handleInput(key: key, current: amount, maxLength: 21, maxDecimals: 6)
                }
                CustomButton(title: t("usdt__deposit_create"), isDisabled: busy || amount.isEmpty, isLoading: busy) {
                    busy = true; error = nil
                    defer { busy = false }
                    do { deposit = try await usdt.prepareDeposit(network: network, amount: amount) }
                    catch { self.error = UsdtWalletManager.message(for: error) }
                }.accessibilityIdentifier("UsdtDepositCreate")
            }
            .onChange(of: amount) { error = nil }
        }
    }
}

extension UsdtDepositNetwork {
    var label: String {
        switch self {
        case .ethereum: "Ethereum"
        case .solana: "Solana"
        case .polygon: "Polygon"
        case .bsc: "BNB Smart Chain"
        case .base: "Base"
        case .tron: "Tron"
        }
    }
}
