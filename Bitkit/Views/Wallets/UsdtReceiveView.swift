import BitkitCore
import SwiftUI

struct UsdtReceiveView: View {
    let tabs: [TabItem<ReceiveQr.ReceiveTab>]
    let onSelectTab: (ReceiveQr.ReceiveTab) -> Void
    var contactAction: AnyView?
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var networks: [UsdtDepositNetwork] = []
    @State private var network: UsdtDepositNetwork?
    @State private var page = Page.address
    @State private var isGoingBack = false
    @State private var pageAfterDirectionChange: Page?
    @State private var amount = ""
    @State private var draftAmount = ""
    @State private var deposit: UsdtDepositAddress?
    @State private var busy = false
    @State private var error: String?

    private enum Page: Comparable { case address, networks, amount, fees }

    private var networkName: String {
        network?.label ?? "Arbitrum One"
    }

    private var title: String {
        switch page {
        case .address: t("usdt__receive_title")
        case .networks: t("usdt__receive_network_title")
        case .amount: t("wallet__receive_amount")
        case .fees: t("usdt__receive_fees_title")
        }
    }

    private var receiveUri: String {
        guard let atomic = try? PaykitAmount(asset: .usdt, value: amount).atomic else { return usdt.receiveUri }
        return usdt.receiveUri + "&uint256=\(atomic)"
    }

    var body: some View {
        ZStack {
            pageContent
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color.gray7)
                .geometryGroup()
                .id(page)
                .transition(isGoingBack ? popTransition : pushTransition)
        }
        .animation(.easeInOut(duration: 0.3), value: page)
        .onChange(of: isGoingBack) {
            if let next = pageAfterDirectionChange {
                pageAfterDirectionChange = nil
                page = next
            }
        }
        .background(Color.gray7)
        .preference(key: SheetBackgroundPreferenceKey.self, value: .gray7)
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

    private var pageContent: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, showBackButton: page != .address, action: page == .address ? contactAction : nil,
                        topPadding: 28, bottomPadding: 22, dragIndicatorTopPadding: 8, onBack: goBack)
                .disabled(busy)
            switch page {
            case .address:
                SegmentedControl(selectedTab: Binding(get: { .usdt }, set: onSelectTab), tabItems: tabs)
                    .padding(.bottom, 16)
                VStack(spacing: 0) {
                    UsdtReceiveAddressContent(
                        address: deposit?.address ?? usdt.address,
                        uri: deposit?.uri ?? receiveUri,
                        network: networkName,
                        amount: amount,
                        error: error ?? usdt.errorMessage,
                        onEdit: { draftAmount = amount; show(.amount) },
                        onNetwork: { show(.networks) }
                    )
                }
                .contentShape(Rectangle())
                .swipeSegmentedTabs(selection: Binding(get: { .usdt }, set: onSelectTab), tabs: tabs.map(\.tab), wrapAround: true, simultaneous: true)
            case .networks:
                networkList
            case .amount:
                amountEntry
            case .fees:
                if let deposit {
                    feeEstimate(deposit)
                }
            }
        }
    }

    private var pushTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
    }

    private var popTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
    }

    /// A page leaving the screen keeps the transition of its last render, so a change of direction is rendered on its own
    /// before the page changes; otherwise the outgoing page slides out on the side the incoming one comes from.
    private func show(_ next: Page) {
        let isBack = next < page
        if isBack == isGoingBack {
            page = next
        } else {
            pageAfterDirectionChange = next
            isGoingBack = isBack
        }
    }

    private func goBack() {
        if page == .amount {
            error = nil
        }
        if page == .fees {
            show(.amount)
        } else if page == .amount, network != nil, deposit == nil {
            show(.networks)
        } else {
            if deposit == nil {
                network = nil
            }
            show(.address)
        }
    }

    private var networkList: some View {
        VStack(spacing: 16) {
            UsdtNetworkPicker(note: t("usdt__receive_network_note")) {
                networkRow(nil)
                ForEach(networks, id: \.self) { networkRow($0) }
            }
            if let error {
                BodySText(error, textColor: .textSecondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 16) {
            if usdt.depositsConfigured {
                CustomButton(title: t("usdt__deposit_history"), titleKerning: 0, titleLineHeight: 20) {
                    sheets.hideSheet()
                    navigation.navigate(.usdtDepositHistory)
                }
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier("UsdtDepositHistory")
            }
        }
    }

    private func networkRow(_ item: UsdtDepositNetwork?) -> some View {
        UsdtNetworkRow(title: item?.label ?? "Arbitrum One", selected: network == item,
                       identifier: "UsdtNetwork-\(item?.label ?? "Arbitrum")")
        {
            if network != item {
                deposit = nil; amount = ""; draftAmount = ""; error = nil
            }
            network = item
            draftAmount = amount
            show(item == nil || deposit != nil ? .address : .amount)
        }
    }

    private var amountEntry: some View {
        UsdtReceiveAmountView(amount: $draftAmount, busy: busy, error: error, allowEmpty: network == nil) {
            guard let network else { amount = draftAmount; show(.address); return }
            busy = true
            error = nil
            defer { busy = false }
            do {
                deposit = try await usdt.prepareDeposit(network: network, amount: draftAmount)
                amount = draftAmount
                show(.fees)
            } catch {
                self.error = usdtDepositAmountMessage(error, amount: draftAmount)
            }
        }
        .onChange(of: draftAmount) { error = nil }
    }

    private func feeEstimate(_ deposit: UsdtDepositAddress) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            UsdtAmountHeader(amount: usdtFormatAmount(amount: deposit.amount), displayAmount: usdtOverviewAmount(deposit.amount))
            BodyMText(t("usdt__deposit_fee_note"), textColor: .textSecondary, kerning: 0, lineHeight: 22)
            VStack(alignment: .leading, spacing: 24) {
                feeRow(
                    t("usdt__receive_fee"),
                    amount: deposit.amount >= deposit.estimatedReceived ? deposit.amount - deposit.estimatedReceived : nil
                )
                feeRow(t("usdt__receive_estimate"), amount: deposit.estimatedReceived)
            }
            Spacer()
            CustomButton(title: t("common__continue"), titleKerning: 0, titleLineHeight: 20) { show(.address) }
                .accessibilityIdentifier("UsdtReceiveFeesContinue")
        }
    }

    private func feeRow(_ title: String, amount: UInt64?) -> some View {
        SendSectionView(title.uppercased(), dividerSpacing: 24, labelKerning: 1, labelLineHeight: 18) {
            HStack(spacing: 4) {
                BodySSBText("± $", textColor: .textSecondary, lineHeight: 20)
                BodySSBText(amount.map { usdtOverviewAmount($0) } ?? "—", kerning: 0, lineHeight: 20)
            }
        }
    }
}

struct UsdtReceiveAddressContent: View {
    let address: String
    let uri: String
    let network: String
    var amount = ""
    var error: String?
    let onEdit: () -> Void
    let onNetwork: () -> Void
    @State private var showDetails = false
    @State private var showShareSheet = false

    private var networkTitle: String {
        t("usdt__receive_network", variables: ["network": network])
    }

    var shareText: String {
        [networkTitle, address, amount.isEmpty ? nil : "\(amount) USDT"].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        if !uri.isEmpty, !showDetails {
            QrArea(uri: uri, imageAsset: "tether-circle", accentColor: .usdtAccent,
                   copyValue: address, shareText: shareText, copyMessage: t("usdt__receive_copied"), onEdit: onEdit)
        } else {
            ScrollView(showsIndicators: false) {
                if !uri.isEmpty {
                    CopyAddressCard(
                        addresses: [CopyAddressPair(title: network + " " + t("wallet__activity_address"), address: address, type: .onchain,
                                                    shareText: shareText)],
                        navigationPath: .constant([]),
                        editRoute: nil,
                        accentColor: .usdtAccent,
                        copyMessage: t("usdt__receive_copied"),
                        onShare: { showShareSheet = true }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("UsdtReceiveAddress")
                } else if let error {
                    BodySText(error, textColor: .brandAccent)
                } else {
                    ProgressView()
                }
            }
        }
        Spacer(minLength: 0)
        CustomButton(
            title: networkTitle,
            variant: .secondary,
            size: .small,
            icon: Image("usdt-network").resizable().frame(width: 16, height: 16),
            shouldExpand: true,
            titleKerning: 0,
            titleLineHeight: 13,
            action: onNetwork
        )
        .padding(.bottom, 16)
        .accessibilityIdentifier("UsdtReceiveNetwork")
        CustomButton(title: t(showDetails ? "wallet__receive_show_qr" : "common__show_details"),
                     icon: showDetails ? Image("qr").resizable().frame(width: 16, height: 16) : nil, shouldExpand: true,
                     titleKerning: 0, titleLineHeight: 20)
        { showDetails.toggle() }.accessibilityIdentifier("UsdtReceiveDetails")
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: [shareText] + (QR.shareImage(content: uri).map { [$0] } ?? []))
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
