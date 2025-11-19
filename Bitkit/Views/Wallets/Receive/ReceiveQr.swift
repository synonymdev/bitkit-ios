import SwiftUI

struct ReceiveQr: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [ReceiveRoute]
    let cjitInvoice: String?
    let tab: ReceiveTab?

    @State private var selectedTab: ReceiveTab
    @State private var showDetails = false

    init(navigationPath: Binding<[ReceiveRoute]>, cjitInvoice: String? = nil, tab: ReceiveTab? = nil) {
        _navigationPath = navigationPath
        self.cjitInvoice = cjitInvoice
        self.tab = tab

        // Default to unified tab if available, otherwise use provided tab or savings
        let defaultTab: ReceiveTab = if tab != nil {
            tab!
        } else {
            // We'll set this in onAppear since we need access to wallet.channelCount
            .savings
        }
        _selectedTab = State(initialValue: defaultTab)
    }

    enum ReceiveTab: CaseIterable, CustomStringConvertible {
        case savings, unified, spending

        var description: String {
            switch self {
            case .savings:
                return t("lightning__savings")
            case .unified:
                return "Auto"
            case .spending:
                return t("lightning__spending")
            }
        }
    }

    /// Check if there are usable channels for Lightning receive
    /// When geoblocked, only count non-LSP channels
    private var hasUsableChannels: Bool {
        if app.isGeoBlocked == true {
            return wallet.hasNonLspChannels()
        } else {
            return wallet.channelCount != 0
        }
    }

    private var availableTabItems: [TabItem<ReceiveTab>] {
        // Only show unified tab if there are usable channels
        if hasUsableChannels {
            return [
                TabItem(.savings),
                TabItem(.unified, activeColor: .white),
                TabItem(.spending, activeColor: .purpleAccent),
            ]
        } else {
            return [
                TabItem(.savings),
                TabItem(.spending, activeColor: .purpleAccent),
            ]
        }
    }

    var showingCjitOnboarding: Bool {
        // Show CJIT onboarding when:
        // 1. No channels at all, OR
        // 2. Geoblocked with only Blocktank channels (treat as no usable channels)
        let hasNoUsableChannels = (wallet.channelCount == 0) ||
            (app.isGeoBlocked == true && !wallet.hasNonLspChannels())
        return hasNoUsableChannels && cjitInvoice == nil && selectedTab == .spending
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__receive_bitcoin"))
                .padding(.horizontal, 16)

            SegmentedControl(selectedTab: $selectedTab, tabItems: availableTabItems)
                .padding(.bottom, 16)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                TabView(selection: $selectedTab) {
                    tabContent(for: .savings)

                    if hasUsableChannels {
                        tabContent(for: .unified)
                    }

                    tabContent(for: .spending)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))

                Spacer()

                Group {
                    if showingCjitOnboarding {
                        CustomButton(
                            title: t("wallet__receive_spending"),
                            icon: Image("bolt")
                                .resizable()
                                .frame(width: 16, height: 16)
                                .foregroundColor(.purpleAccent),
                            isDisabled: wallet.nodeLifecycleState != .running
                        ) {
                            // Check if geoblocked with only Blocktank channels
                            if app.isGeoBlocked == true && !wallet.hasNonLspChannels() {
                                app.toast(
                                    type: .error,
                                    title: "Instant Payments Unavailable",
                                    description: "Bitkit does not provide Lightning services in your country, but you can still connect to other nodes."
                                )
                            } else {
                                navigationPath.append(.cjitAmount)
                            }
                        }
                    } else {
                        CustomButton(title: showDetails ? tTodo("QR Code") : tTodo("Show Details")) {
                            showDetails.toggle()
                        }
                        .accessibilityIdentifier(showDetails ? "QRCode" : "ShowDetails")
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                // Set default tab to unified if available and no tab was provided
                if tab == nil && wallet.channelCount != 0 {
                    selectedTab = .unified
                }
            }
        }
        .navigationBarHidden(true)
        .sheetBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ReceiveScreen")
        .task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { await refreshBip21() }
                    group.addTask { try await blocktank.refreshInfo() }
                    try await group.waitForAll()
                }
            } catch {
                app.toast(error)
            }
        }
        .onChange(of: wallet.nodeLifecycleState) { newState in
            // They may open this view before node has started
            if newState == .running {
                Task {
                    await refreshBip21()
                }
            }
        }
    }

    @ViewBuilder
    func tabContent(for tab: ReceiveTab) -> some View {
        VStack(spacing: 0) {
            if showingCjitOnboarding {
                cjitOnboarding
            } else if showDetails {
                detailsContent(for: tab)
            } else {
                qrContent(for: tab)
            }

            Spacer()
        }
        .padding(.horizontal)
        .tag(tab)
    }

    @ViewBuilder
    func qrContent(for tab: ReceiveTab) -> some View {
        let config = qrConfig(for: tab)

        if !config.uri.isEmpty {
            QrArea(uri: config.uri, imageAsset: config.imageAsset, accentColor: config.accentColor, navigationPath: $navigationPath)
        } else {
            ProgressView()
        }
    }

    private func qrConfig(for tab: ReceiveTab) -> (uri: String, imageAsset: String, accentColor: Color) {
        switch tab {
        case .savings:
            return (
                uri: stripLightningFromBip21(wallet.bip21),
                imageAsset: "btc",
                accentColor: .brandAccent
            )
        case .unified:
            return (
                uri: wallet.bip21,
                imageAsset: "btc-and-ln",
                accentColor: .brandAccent
            )
        case .spending:
            return (
                uri: cjitInvoice ?? wallet.bolt11,
                imageAsset: "ln",
                accentColor: .purpleAccent
            )
        }
    }

    var cjitOnboarding: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(tTodo("Receive on <accent>spending balance</accent>"), accentColor: .purpleAccent)
                .padding(.bottom, 12)

            BodyMText(tTodo("Enjoy instant and cheap\ntransactions with friends, family,\nand merchants."))

            Spacer()

            HStack {
                Spacer()
                Image("bolt")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .foregroundColor(.purpleAccent)
                Spacer()
            }
        }
        .padding(32)
        .background(Color.black)
        .cornerRadius(8)
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            if !UIScreen.main.isSmall {
                Image("arrow-cjit")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 210)
                    .offset(x: 70, y: 110)
            }
        }
    }

    @ViewBuilder
    func detailsContent(for tab: ReceiveTab) -> some View {
        VStack {
            let addressPairs: [CopyAddressPair] = {
                var pairs: [CopyAddressPair] = []

                switch tab {
                case .savings:
                    // Savings: only onchain address
                    if !wallet.onchainAddress.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: t("wallet__receive_bitcoin_invoice"),
                                address: wallet.onchainAddress,
                                type: .onchain
                            )
                        )
                    }
                case .spending:
                    // Spending: cjitInvoice or bolt11
                    if let cjitInvoice {
                        pairs.append(
                            CopyAddressPair(
                                title: t("wallet__receive_lightning_invoice"),
                                address: cjitInvoice,
                                type: .lightning
                            )
                        )
                        break
                    }

                    if !wallet.bolt11.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: t("wallet__receive_lightning_invoice"),
                                address: wallet.bolt11,
                                type: .lightning
                            )
                        )
                    }
                case .unified:
                    // Unified: both onchain and lightning
                    if !wallet.onchainAddress.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: t("wallet__receive_bitcoin_invoice"),
                                address: wallet.onchainAddress,
                                type: .onchain
                            )
                        )
                    }

                    if !wallet.bolt11.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: t("wallet__receive_lightning_invoice"),
                                address: wallet.bolt11,
                                type: .lightning
                            )
                        )
                    }
                }

                return pairs
            }()

            if !addressPairs.isEmpty {
                CopyAddressCard(addresses: addressPairs, navigationPath: $navigationPath)
            }

            Spacer()
        }
    }

    private struct ImageConfig {
        let name: String
        let offset: (x: CGFloat, y: CGFloat)
    }

    func refreshBip21() async {
        guard wallet.nodeLifecycleState == .running else { return }
        do {
            let isGeoblocked = app.isGeoBlocked ?? false
            try await wallet.refreshBip21(isGeoblocked: isGeoblocked)
        } catch {
            app.toast(error)
        }
    }

    /// Strips the lightning parameter from a BIP21 URI while keeping other parameters
    /// - Parameter bip21: The original BIP21 URI string
    /// - Returns: BIP21 URI with lightning parameter removed
    private func stripLightningFromBip21(_ bip21: String) -> String {
        guard let url = URL(string: bip21),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return bip21
        }

        // Filter out lightning parameter but keep other parameters like amount
        let filteredQueryItems = components.queryItems?.filter { $0.name != "lightning" } ?? []

        var newComponents = components
        newComponents.queryItems = filteredQueryItems.isEmpty ? nil : filteredQueryItems

        return newComponents.url?.absoluteString ?? bip21
    }
}
