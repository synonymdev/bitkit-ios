import BitkitCore
import SwiftUI

struct UsdtReceiveView: View {
    let tabs: [TabItem<ReceiveQr.ReceiveTab>]
    let onSelectTab: (ReceiveQr.ReceiveTab) -> Void
    var contactAction: AnyView?
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var networks: [UsdtDepositNetwork] = []
    @State private var network: UsdtDepositNetwork?
    @State private var page = Page.address
    @State private var historyBlocking = false
    @State private var amount = ""
    @State private var deposit: UsdtDepositAddress?
    @State private var busy = false
    @State private var error: String?

    private enum Page { case address, networks, amount, fees, history }

    private var networkName: String {
        network?.label ?? "Arbitrum One"
    }

    private var title: String {
        switch page {
        case .address: t("usdt__receive_title")
        case .networks: t("usdt__receive_network_title")
        case .amount: t("wallet__receive_amount")
        case .fees: t("usdt__receive_fees_title")
        case .history: t("usdt__deposit_history")
        }
    }

    private var receiveUri: String {
        guard let atomic = try? PaykitAmount(asset: .usdt, value: amount).atomic else { return usdt.receiveUri }
        return usdt.receiveUri + "&uint256=\(atomic)"
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, showBackButton: page != .address, action: page == .address ? contactAction : nil,
                        onBack: {
                            if page == .fees { page = .amount }
                            else if page == .amount, network != nil, deposit == nil { page = .networks }
                            else { if deposit == nil { network = nil }; page = .address }
                        })
                        .disabled(busy || historyBlocking)
            switch page {
            case .address:
                SegmentedControl(selectedTab: Binding(get: { .usdt }, set: onSelectTab), tabItems: tabs)
                    .padding(.bottom, 16)
                UsdtReceiveAddressContent(
                    address: deposit?.address ?? usdt.address,
                    uri: deposit?.uri ?? receiveUri,
                    network: networkName,
                    isDefaultNetwork: network == nil,
                    error: error ?? usdt.errorMessage,
                    onEdit: { page = .amount },
                    onNetwork: { page = .networks }
                )
            case .networks:
                networkList
            case .amount:
                amountEntry
            case .fees:
                if let deposit { feeEstimate(deposit) }
            case .history:
                UsdtDepositHistoryView(onBlockingChange: { historyBlocking = $0 })
            }
        }
        .padding(.horizontal, 16)
        .onReceive(usdt.receivedTxPublisher) { transfer in
            guard !historyBlocking, sheets.activeSheetConfiguration?.id == .receive else { return }
            sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, usdtAmount: transfer.amount, usdtTransferId: transfer.id))
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
            catch is CancellationError {} catch { self.error = t("usdt__deposit_unavailable") }
        }
    }

    private var networkList: some View {
        ScrollView {
            VStack(spacing: 8) {
                networkRow(nil)
                ForEach(networks, id: \.self) { networkRow($0) }
                BodySText(t("usdt__receive_network_note"), textColor: .textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                UsdtCoinIllustration()
                if usdt.depositsConfigured {
                    CustomButton(title: t("usdt__deposit_history"), variant: .tertiary) { page = .history }
                        .accessibilityIdentifier("UsdtDepositHistory")
                }
                if let error { BodySText(error, textColor: .textSecondary) }
            }
        }
    }

    private func networkRow(_ item: UsdtDepositNetwork?) -> some View {
        Button {
            if network != item { deposit = nil; amount = ""; error = nil }
            network = item
            page = item == nil || deposit != nil ? .address : .amount
        } label: {
            HStack(spacing: 16) {
                Image("tether").resizable().frame(width: 40, height: 40)
                BodyMSBText(item?.label ?? "Arbitrum One")
                if item == nil { BodySText(t("common__default"), textColor: .textSecondary) }
                Spacer()
                if network == item { Image("check-mark").resizable().frame(width: 24, height: 24).foregroundColor(.usdtAccent) }
            }
            .padding(16).background(Color.gray6).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("UsdtNetwork-\(item?.label ?? "Arbitrum")")
    }

    private var amountEntry: some View {
        UsdtReceiveAmountView(amount: $amount, busy: busy, error: error, allowEmpty: network == nil) {
            guard let network else { page = .address; return }
            busy = true
            error = nil
            defer { busy = false }
            do {
                deposit = try await usdt.prepareDeposit(network: network, amount: amount)
                page = .fees
            } catch {
                self.error = usdtDepositAmountMessage(error, amount: amount)
            }
        }
        .onChange(of: amount) { error = nil }
    }

    private func feeEstimate(_ deposit: UsdtDepositAddress) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            UsdtAmountHeader(amount: usdtFormatAmount(amount: deposit.amount))
            BodyMText(t("usdt__deposit_fee_note"), textColor: .textSecondary)
            VStack(alignment: .leading, spacing: 24) {
                feeRow(
                    t("usdt__receive_fee"),
                    amount: deposit.amount >= deposit.estimatedReceived ? deposit.amount - deposit.estimatedReceived : nil
                )
                feeRow(t("usdt__receive_estimate"), amount: deposit.estimatedReceived)
            }
            Spacer()
            CustomButton(title: t("common__continue")) { page = .address }
                .accessibilityIdentifier("UsdtReceiveFeesContinue")
        }
    }

    private func feeRow(_ title: String, amount: UInt64?) -> some View {
        SendSectionView(title.uppercased(), dividerSpacing: 24) {
            BodyMSBText("<accent>± $</accent> " + (amount.map { usdtFormatAmount(amount: $0) } ?? "—"), accentColor: .textSecondary)
        }
    }
}

struct UsdtReceiveAddressContent: View {
    let address: String
    let uri: String
    let network: String
    let isDefaultNetwork: Bool
    var error: String?
    let onEdit: () -> Void
    let onNetwork: () -> Void
    @State private var showDetails = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            if !uri.isEmpty {
                if showDetails {
                    CopyAddressCard(
                        addresses: [CopyAddressPair(title: network + " " + t("wallet__activity_address"), address: address, type: .onchain)],
                        navigationPath: .constant([]),
                        editRoute: nil,
                        accentColor: .usdtAccent
                    )
                    .accessibilityIdentifier("UsdtReceiveAddress")
                } else {
                    QrArea(uri: uri, imageAsset: "tether-circle", accentColor: .usdtAccent,
                           copyValue: address, onEdit: onEdit)
                }
            } else if let error { BodySText(error, textColor: .brandAccent) }
            else { ProgressView() }
        }
        CustomButton(
            title: t("usdt__receive_network", variables: ["network": isDefaultNetwork ? t("common__default") : network]),
            variant: .secondary,
            size: .small,
            icon: Image("usdt-network").resizable().frame(width: 16, height: 16),
            shouldExpand: true,
            action: onNetwork
        )
        .padding(.bottom, 16)
        .accessibilityIdentifier("UsdtReceiveNetwork")
        CustomButton(title: t(showDetails ? "wallet__receive_show_qr" : "common__show_details"),
                     icon: showDetails ? Image("qr").resizable().frame(width: 16, height: 16) : nil, shouldExpand: true)
        { showDetails.toggle() }.accessibilityIdentifier("UsdtReceiveDetails")
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
