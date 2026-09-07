import SwiftUI

struct ReceiveQr: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Binding var navigationPath: [ReceiveRoute]
    let cjitInvoice: String?
    let tab: ReceiveTab?
    let hardwareWalletId: String?

    @State private var selectedTab: ReceiveTab
    @State private var showDetails = false
    @State private var hasAppliedDefaultTab = false
    @State private var hardwareAddress: HwReceiveAddress?
    @State private var hardwareAddressLoadFailed = false
    @State private var isLoadingHardwareAddress = false
    @State private var isVerifyingHardwareAddress = false
    @State private var isPassphraseRequired = false
    @State private var isVerifyingPassphrase = false
    @State private var verifyTask: Task<Void, Never>?
    @State private var passphraseTask: Task<Void, Never>?

    init(
        navigationPath: Binding<[ReceiveRoute]>,
        cjitInvoice: String? = nil,
        tab: ReceiveTab? = nil,
        hardwareWalletId: String? = nil
    ) {
        _navigationPath = navigationPath
        self.cjitInvoice = cjitInvoice
        self.tab = tab
        self.hardwareWalletId = hardwareWalletId

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
        case savings, unified, spending, trezor

        var description: String {
            switch self {
            case .savings:
                return t("lightning__savings")
            case .unified:
                return "Auto"
            case .spending:
                return t("lightning__spending")
            case .trezor:
                return t("hardware__device_model_trezor")
            }
        }
    }

    private var availableTabItems: [TabItem<ReceiveTab>] {
        var items: [TabItem<ReceiveTab>]
            // Show unified tab when we have a Lightning invoice (even if channels not yet usable)
            = if !wallet.bolt11.isEmpty
        {
            [
                TabItem(.savings),
                TabItem(.unified),
                TabItem(.spending),
            ]
        } else {
            [
                TabItem(.savings),
                TabItem(.spending),
            ]
        }
        if selectedHardwareWalletId != nil {
            items.insert(TabItem(.trezor), at: 0)
        }
        return items
    }

    private var selectedHardwareWalletId: String? {
        if let hardwareWalletId { return hardwareWalletId }
        guard hwWalletManager.wallets.count == 1 else { return nil }
        return hwWalletManager.wallets.first?.id
    }

    private var displayedHardwareAddress: HwReceiveAddress? {
        guard let walletId = selectedHardwareWalletId else { return nil }
        return hwWalletManager.watcherReceiveAddress(walletId: walletId) ?? hardwareAddress
    }

    var showingCjitOnboarding: Bool {
        return !wallet.hasReadyChannels && cjitInvoice == nil && selectedTab == .spending
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__receive_bitcoin"))
                .padding(.horizontal, 16)
                .padding(.bottom, UIScreen.main.isSmall ? -16 : 0)

            SegmentedControl(selectedTab: $selectedTab, tabItems: availableTabItems)
                .padding(.bottom, 16)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                TabView(selection: $selectedTab) {
                    if selectedHardwareWalletId != nil {
                        tabContent(for: .trezor)
                    }

                    tabContent(for: .savings)

                    if !wallet.bolt11.isEmpty {
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
                            if !wallet.hasReadyChannels && !GeoService.shared.isGeoBlocked {
                                navigationPath.append(.cjitAmount)
                            } else if GeoService.shared.isGeoBlocked {
                                navigationPath.append(.cjitGeoBlocked)
                            }
                        }
                    } else if showDetails {
                        VStack(spacing: 16) {
                            if selectedTab == .trezor {
                                CustomButton(
                                    title: t("hardware__verify_address"),
                                    variant: .secondary,
                                    isDisabled: displayedHardwareAddress == nil,
                                    isLoading: isVerifyingHardwareAddress,
                                    shouldExpand: true
                                ) {
                                    startHardwareAddressVerification()
                                }
                                .accessibilityIdentifier("HardwareVerifyAddress")
                            }

                            CustomButton(
                                title: t("wallet__receive_show_qr"),
                                icon: Image("qr")
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(.textPrimary)
                            ) {
                                showDetails.toggle()
                            }
                            .accessibilityIdentifier("QRCode")
                        }
                    } else {
                        CustomButton(
                            title: t("common__show_details"),
                            variant: .tertiary,
                            isDisabled: selectedTab == .trezor && displayedHardwareAddress == nil
                        ) {
                            showDetails.toggle()
                        }
                        .accessibilityIdentifier("ShowDetails")
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selectedTab) { _, newTab in
                showDetails = false
                if newTab == .trezor {
                    Task { await loadHardwareAddress() }
                } else {
                    verifyTask?.cancel()
                    verifyTask = nil
                }
            }
            .onAppear {
                // Apply the default-tab choice at most once, on the first appearance. The flag is set
                // unconditionally here (even before bolt11 is ready) so a later reappearance — e.g.
                // returning from Edit once the invoice has loaded — can never override the tab the user picked.
                if !hasAppliedDefaultTab {
                    hasAppliedDefaultTab = true
                    // Default to the unified ("Auto") tab when a Lightning invoice is already available.
                    if tab == nil && !wallet.bolt11.isEmpty {
                        selectedTab = .unified
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheetBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ReceiveScreen")
        .sheet(isPresented: passphrasePromptBinding) {
            HwPassphrasePromptSheet(
                isVerifying: isVerifyingPassphrase,
                onSubmit: reconnectWithPassphrase,
                onCancel: dismissPassphrase
            )
        }
        .task(id: selectedHardwareWalletId) {
            if selectedTab == .trezor {
                await loadHardwareAddress()
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
            await app.checkGeoStatus()
        }
        .onChange(of: wallet.nodeLifecycleState) { _, newState in
            // They may open this view before node has started
            if newState == .running {
                Task {
                    await refreshBip21()
                }
            }
        }
        .onDisappear {
            verifyTask?.cancel()
            verifyTask = nil
            passphraseTask?.cancel()
            passphraseTask = nil
        }
    }

    func tabContent(for tab: ReceiveTab) -> some View {
        VStack(spacing: 0) {
            if tab == .spending && wallet.channelCount == 0 && cjitInvoice == nil {
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
        if tab == .trezor {
            if let hardwareAddress = displayedHardwareAddress {
                let uri = Bip21Utils.hardwareInvoice(
                    address: hardwareAddress.address,
                    amountSats: wallet.invoiceAmountSats,
                    message: wallet.invoiceNote
                )
                QrArea(
                    uri: uri,
                    imageAsset: "btc-circle-blue",
                    accentColor: .blueAccent,
                    navigationPath: $navigationPath,
                    copyValue: uri.contains("?") ? uri : hardwareAddress.address,
                    editRoute: .edit(onchainOnly: true)
                )
            } else if hardwareAddressLoadFailed {
                VStack(spacing: 16) {
                    BodyMText(t("hardware__receive_address_error"), textColor: .textSecondary)
                        .multilineTextAlignment(.center)
                    CustomButton(title: t("common__try_again"), variant: .tertiary) {
                        await loadHardwareAddress()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoadingHardwareAddress {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            let config = qrConfig(for: tab)

            if !config.uri.isEmpty {
                QrArea(
                    uri: config.uri,
                    imageAsset: config.imageAsset,
                    accentColor: config.accentColor,
                    navigationPath: $navigationPath
                )
            } else {
                ProgressView()
            }
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
        case .trezor:
            return (uri: "", imageAsset: "btc-circle-blue", accentColor: .blueAccent)
        }
    }

    var cjitOnboarding: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(t("wallet__receive_spending_title"), accentColor: .purpleAccent)
                .padding(.bottom, 12)

            BodyMText(t("wallet__receive_spending_text"))

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
                case .trezor:
                    if let hardwareAddress = displayedHardwareAddress {
                        pairs.append(
                            CopyAddressPair(
                                title: t("wallet__receive_bitcoin_invoice"),
                                address: hardwareAddress.address,
                                type: .onchain
                            )
                        )
                    }
                }

                return pairs
            }()

            if !addressPairs.isEmpty {
                CopyAddressCard(
                    addresses: addressPairs,
                    navigationPath: $navigationPath,
                    editRoute: .edit(onchainOnly: tab == .trezor),
                    accentColor: tab == .trezor ? .blueAccent : nil
                )
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
            try await wallet.refreshBip21()
        } catch {
            app.toast(error)
        }
    }

    private var passphrasePromptBinding: Binding<Bool> {
        Binding(
            get: { isPassphraseRequired },
            set: { if !$0 { dismissPassphrase() } }
        )
    }

    @MainActor
    private func loadHardwareAddress() async {
        guard let walletId = selectedHardwareWalletId else {
            hardwareAddress = nil
            hardwareAddressLoadFailed = false
            return
        }
        isLoadingHardwareAddress = true
        hardwareAddressLoadFailed = false
        defer { isLoadingHardwareAddress = false }
        do {
            let address = try await hwWalletManager.getReceiveAddress(walletId: walletId)
            guard selectedHardwareWalletId == walletId else { return }
            hardwareAddress = address
        } catch is CancellationError {
            return
        } catch {
            hardwareAddress = nil
            hardwareAddressLoadFailed = true
            Logger.error(error, context: "ReceiveQr failed to load hardware address")
        }
    }

    @MainActor
    private func verifyHardwareAddress() async {
        guard !isVerifyingHardwareAddress,
              let walletId = selectedHardwareWalletId,
              let hardwareAddress = displayedHardwareAddress
        else { return }

        isVerifyingHardwareAddress = true
        defer { isVerifyingHardwareAddress = false }
        do {
            try await hwWalletManager.verifyReceiveAddress(walletId: walletId, receiveAddress: hardwareAddress)
        } catch is CancellationError {
            return
        } catch HwPassphraseError.required {
            isPassphraseRequired = true
        } catch {
            if !error.isTrezorUserCancellation() {
                app.toast(error)
            }
        }
    }

    private func startHardwareAddressVerification() {
        guard verifyTask == nil else { return }
        verifyTask = Task { @MainActor in
            defer { verifyTask = nil }
            await verifyHardwareAddress()
        }
    }

    private func reconnectWithPassphrase(_ passphrase: String) {
        guard passphraseTask == nil, let walletId = selectedHardwareWalletId else { return }
        isVerifyingPassphrase = true
        passphraseTask = Task { @MainActor in
            defer {
                isVerifyingPassphrase = false
                passphraseTask = nil
            }
            do {
                try await hwWalletManager.reconnectWithPassphrase(walletId: walletId, passphrase: passphrase)
                guard isPassphraseRequired else { throw CancellationError() }
                isPassphraseRequired = false
                await verifyHardwareAddress()
            } catch is CancellationError {
                return
            } catch HwPassphraseError.mismatch {
                app.toast(HwTransferError.passphraseMismatch)
            } catch {
                if !error.isTrezorUserCancellation() {
                    app.toast(error)
                }
            }
        }
    }

    private func dismissPassphrase() {
        passphraseTask?.cancel()
        isPassphraseRequired = false
        isVerifyingPassphrase = false
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
