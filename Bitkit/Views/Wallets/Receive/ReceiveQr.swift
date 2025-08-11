import SwiftUI

struct ReceiveQr: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [ReceiveRoute]
    let cjitInvoice: String?
    let tab: ReceiveTab?

    @State private var selectedTab: ReceiveTab
    @State private var cjitActive = false
    @State private var showTechnicalDetails = false

    init(navigationPath: Binding<[ReceiveRoute]>, cjitInvoice: String? = nil, tab: ReceiveTab? = nil) {
        self._navigationPath = navigationPath
        self.cjitInvoice = cjitInvoice
        self.tab = tab

        // Default to unified tab if available, otherwise use provided tab or savings
        let defaultTab: ReceiveTab
        if tab != nil {
            defaultTab = tab!
        } else {
            // We'll set this in onAppear since we need access to wallet.channelCount
            defaultTab = .savings
        }
        self._selectedTab = State(initialValue: defaultTab)
    }

    enum ReceiveTab: CaseIterable, CustomStringConvertible {
        case savings, unified, spending

        var description: String {
            switch self {
            case .savings:
                return localizedString("lightning__savings")
            case .unified:
                return "Auto"
            case .spending:
                return localizedString("lightning__spending")
            }
        }
    }

    private var availableTabItems: [TabItem<ReceiveTab>] {
        // Only show unified tab if there are channels
        if wallet.channelCount != 0 {
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

    var body: some View {
        ZStack {
            backgroundImage

            VStack(spacing: 0) {
                SheetHeader(title: localizedString("wallet__receive_bitcoin"))

                SegmentedControl(selectedTab: $selectedTab, tabItems: availableTabItems)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    TabView(selection: $selectedTab) {
                        if showTechnicalDetails {
                            copyValues
                                .padding(.horizontal)
                                .tag(ReceiveTab.savings)
                        } else {
                            savingsQr
                                .padding(.horizontal)
                                .tag(ReceiveTab.savings)
                        }

                        if wallet.channelCount != 0 {
                            if showTechnicalDetails {
                                copyValues
                                    .padding(.horizontal)
                                    .tag(ReceiveTab.unified)
                            } else {
                                unifiedQr
                                    .padding(.horizontal)
                                    .tag(ReceiveTab.unified)
                            }
                        }

                        if showTechnicalDetails {
                            copyValues
                                .padding(.horizontal)
                                .tag(ReceiveTab.spending)
                        } else {
                            spendingQr
                                .padding(.horizontal)
                                .tag(ReceiveTab.spending)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))

                    Spacer()

                    bottomButton
                        .padding(.horizontal, 16)
                }

                .onAppear {
                    // Set cjitActive based on cjitInvoice when the view appears
                    cjitActive = cjitInvoice != nil

                    // Set default tab to unified if available and no tab was provided
                    if tab == nil && wallet.channelCount != 0 {
                        selectedTab = .unified
                    }
                }
            }
        }

        .navigationBarHidden(true)
        .sheetBackground()
        .onDisappear {
            if wallet.invoiceAmountSats > 0 && !wallet.invoiceNote.isEmpty {
                wallet.invoiceAmountSats = 0
                wallet.invoiceNote = ""
                Task {
                    try? await wallet.refreshBip21(forceRefreshBolt11: true)
                }
                Logger.info("ReceiveView closed, reset invoice amount and note")
            }
        }
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
            //They may open this view before node has started
            if newState == .running {
                Task {
                    await refreshBip21()
                }
            }
        }
    }

    @ViewBuilder
    var savingsQr: some View {
        // Strip lightning invoice only, keep other parameters like amount
        let uri: String = {
            let bip21 = wallet.bip21
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
        }()

        VStack(spacing: 0) {
            if !uri.isEmpty {
                QrArea(uri: uri, imageAsset: "btc", accentColor: .brandAccent, navigationPath: $navigationPath)
            } else {
                ProgressView()
            }

            Spacer()
        }
    }

    @ViewBuilder
    var unifiedQr: some View {
        let uri = cjitInvoice ?? wallet.bip21

        // Determine the appropriate image asset based on available content
        let imageAsset: String? = {
            if let cjitInvoice = cjitInvoice, !cjitInvoice.isEmpty {
                return "ln"
            } else if !wallet.bolt11.isEmpty && !wallet.onchainAddress.isEmpty {
                return "btc-and-ln"
            } else if !wallet.onchainAddress.isEmpty {
                return "btc"
            }
            return nil
        }()

        VStack(spacing: 0) {
            if !uri.isEmpty {
                QrArea(uri: uri, imageAsset: imageAsset, accentColor: .brandAccent, navigationPath: $navigationPath)
            } else {
                ProgressView()
            }

            Spacer()
        }
    }

    @ViewBuilder
    var spendingQr: some View {
        let uri = cjitInvoice ?? wallet.bolt11

        VStack(spacing: 0) {
            if !uri.isEmpty {
                QrArea(uri: uri, imageAsset: "ln", accentColor: .purpleAccent, navigationPath: $navigationPath)
            } else {
                // ProgressView()
                spendingEmpty
            }

            Spacer()
        }
    }

    var spendingEmpty: some View {
        VStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                DisplayText("Receive on <accent>spending balance</accent>", accentColor: .purpleAccent)
                    .padding(.bottom, 8)

                BodyMText("Enjoy instant and cheap\ntransactions with friends, family,\nand merchants.")

                Spacer()
            }
            .padding(32)
            .background(Color.white06)
            .cornerRadius(8)

            Image("arrow-cjit")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 82)
                .offset(x: -55)
                .padding(.top, 16)
        }
    }

    @ViewBuilder
    var copyValues: some View {
        VStack {
            let addressPairs: [CopyAddressPair] = {
                var pairs: [CopyAddressPair] = []

                switch selectedTab {
                case .savings:
                    // Savings: only onchain address
                    if !wallet.onchainAddress.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: localizedString("wallet__receive_bitcoin_invoice"),
                                address: wallet.onchainAddress,
                                type: .onchain
                            ))
                    }
                case .spending:
                    // Spending: bolt11 or cjitInvoice
                    if !wallet.bolt11.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: localizedString("wallet__receive_lightning_invoice"),
                                address: wallet.bolt11,
                                type: .lightning
                            ))
                    } else if let cjitInvoice = cjitInvoice {
                        pairs.append(
                            CopyAddressPair(
                                title: localizedString("wallet__receive_lightning_invoice"),
                                address: cjitInvoice,
                                type: .lightning
                            ))
                    }
                case .unified:
                    // Unified: both onchain and lightning
                    if !wallet.onchainAddress.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: localizedString("wallet__receive_bitcoin_invoice"),
                                address: wallet.onchainAddress,
                                type: .onchain
                            ))
                    }

                    if !wallet.bolt11.isEmpty {
                        pairs.append(
                            CopyAddressPair(
                                title: localizedString("wallet__receive_lightning_invoice"),
                                address: wallet.bolt11,
                                type: .lightning
                            ))
                    } else if let cjitInvoice = cjitInvoice {
                        pairs.append(
                            CopyAddressPair(
                                title: localizedString("wallet__receive_lightning_invoice"),
                                address: cjitInvoice,
                                type: .lightning
                            ))
                    }
                }

                return pairs
            }()

            if !addressPairs.isEmpty {
                CopyAddressCard(addresses: addressPairs)
            }

            Spacer()
        }
    }

    @ViewBuilder
    var bottomButton: some View {
        if wallet.channelCount == 0 && cjitInvoice == nil {
            if wallet.nodeLifecycleState == .running || wallet.nodeLifecycleState == .starting {
                CustomButton(
                    title: localizedString("wallet__receive_spending"),
                    icon: Image("bolt").foregroundColor(.purpleAccent)
                ) {
                    navigationPath.append(.cjitAmount)
                }
            }
        } else {
            if showTechnicalDetails {
                CustomButton(
                    title: "Show QR Code",
                    icon: Image("qr")
                        .resizable()
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                ) {
                    showTechnicalDetails.toggle()
                }
            } else {
                CustomButton(
                    title: "Technical Details",
                    variant: .secondary,
                    size: .small,
                ) {
                    showTechnicalDetails.toggle()
                }
            }
        }
    }

    private struct ImageConfig {
        let name: String
        let offset: (x: CGFloat, y: CGFloat)
    }

    @ViewBuilder
    var backgroundImage: some View {
        let imageConfig: ImageConfig = {
            switch selectedTab {
            case .savings:
                return ImageConfig(name: "piggybank", offset: (x: 115, y: 60))
            case .unified:
                return ImageConfig(name: "bitcoin-emboss", offset: (x: 90, y: 70))
            case .spending:
                return ImageConfig(name: "coin-stack-x-2", offset: (x: 120, y: 75))
            }
        }()

        VStack {
            Spacer()
            HStack {
                Spacer()
                Image(imageConfig.name)
                    .resizable()
                    .frame(width: 256, height: 256)
                    .offset(x: imageConfig.offset.x, y: imageConfig.offset.y)
            }
        }
        .edgesIgnoringSafeArea(.bottom)
    }

    func refreshBip21() async {
        guard wallet.nodeLifecycleState == .running else { return }
        do {
            try await wallet.refreshBip21()
        } catch {
            app.toast(error)
        }
    }
}
