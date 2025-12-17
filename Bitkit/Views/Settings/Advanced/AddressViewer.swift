import BitkitCore
import SwiftUI

enum AddressType: CaseIterable, CustomStringConvertible {
    case receiving, change

    var description: String {
        switch self {
        case .receiving:
            return "Receiving Addresses"
        case .change:
            return "Change Addresses"
        }
    }
}

struct AddressViewer: View {
    @EnvironmentObject var app: AppViewModel

    @State private var addresses: [BitkitCore.AddressInfo] = []
    @State private var addressBalances: [String: UInt64] = [:]
    @State private var loadedCount: UInt32 = 20
    @State private var isLoading = false
    @State private var isLoadingBalances = false
    @State private var selectedAddressType: AddressType = .receiving
    @State private var searchText = ""
    @State private var selectedAddress: String = ""
    @State private var showScrollToTop = false

    private let initialLoadCount: UInt32 = 20
    private let loadMoreCount: UInt32 = 20
    private let walletIndex = 0

    private var addressTypeTabItems: [TabItem<AddressType>] {
        [
            TabItem(.receiving),
            TabItem(.change),
        ]
    }

    private var defaultDerivationPath: String {
        // BIP44 derivation path: m/purpose'/coin_type'/account'/change/address_index
        // Purpose 84 = P2WPKH (Native SegWit)
        // Coin type: 0 = Bitcoin mainnet, 1 = Bitcoin testnet/regtest
        let coinType = Env.network == .bitcoin ? "0" : "1"
        return "m/84'/\(coinType)'/0'/0" // P2WPKH path
    }

    // Get the first address for QR display
    private var firstAddress: String {
        addresses.first?.address ?? ""
    }

    // Get the currently selected address for QR display, fallback to first address
    private var displayAddress: String {
        if !selectedAddress.isEmpty {
            return selectedAddress
        }
        return firstAddress
    }

    // Get the index of the currently selected address
    private var selectedAddressIndex: Int {
        if !selectedAddress.isEmpty,
           let index = addresses.firstIndex(where: { $0.address == selectedAddress })
        {
            return index
        }
        return 0 // Default to first address index
    }

    private var filteredAddresses: [BitkitCore.AddressInfo] {
        if searchText.isEmpty {
            return addresses
        }
        return addresses.filter { address in
            address.address.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("settings__adv__address_viewer"))

            // Header with QR Code
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    if !displayAddress.isEmpty {
                        QR(content: displayAddress)
                            .frame(width: 120, height: 120)
                            .onTapGesture {
                                UIPasteboard.general.string = displayAddress
                                Haptics.play(.copiedToClipboard)
                                app.toast(type: .success, title: t("common__copied"), description: displayAddress)
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        CaptionText("Index: \(selectedAddressIndex)", textColor: .white80)
                        CaptionText("Path: \(defaultDerivationPath)/\(selectedAddressIndex)", textColor: .white80)
                        Button {
                            guard !displayAddress.isEmpty else { return }

                            BlockExplorerHelper.openBlockExplorer(
                                id: displayAddress,
                                type: .address
                            )
                        } label: {
                            CaptionText(t("wallet__activity_explorer"), textColor: .white80)
                        }
                        .disabled(displayAddress.isEmpty)
                    }

                    Spacer()
                }
            }
            .padding(.bottom, 24)

            // Search Bar
            HStack(spacing: 0) {
                Image("magnifying-glass")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.white64)
                TextField(
                    t("common__search"), text: $searchText, backgroundColor: .clear,
                    font: .custom(Fonts.regular, size: 17)
                )
            }
            .frame(height: 48)
            .padding(.horizontal)
            .background(Color.white10)
            .cornerRadius(32)
            .padding(.bottom, 16)

            // Address Type Toggle
            SegmentedControl(selectedTab: $selectedAddressType, tabItems: addressTypeTabItems)
                .padding(.bottom, 16)

            // Address List with Sticky Bottom Buttons
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            // Top anchor for scroll to top and visibility detector
                            Color.clear
                                .frame(height: 1)
                                .id("top")
                                .onAppear {
                                    // Hide button when top anchor is visible
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showScrollToTop = false
                                    }
                                }

                            ForEach(Array(filteredAddresses.enumerated()), id: \.offset) { index, address in
                                AddressRow(
                                    index: index,
                                    address: address.address,
                                    balance: addressBalances[address.address],
                                    isSelected: selectedAddress == address.address
                                ) {
                                    selectedAddress = address.address
                                }
                                .onAppear {
                                    // Show scroll to top button when we have addresses and user scrolled down
                                    if index > 3 {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            showScrollToTop = true
                                        }
                                    }
                                }
                            }

                            // Add bottom padding to prevent content from being hidden behind sticky buttons
                            Color.clear
                                .frame(height: 80)
                        }
                    }
                    .onChange(of: selectedAddressType) { _ in
                        // Reset scroll position when switching address types
                        selectedAddress = ""
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo("top", anchor: .top)
                            showScrollToTop = false
                        }
                        Task {
                            await loadAddresses()
                        }
                    }
                    .onChange(of: searchText) { _ in
                        // Reset scroll position when searching
                        withAnimation(.easeInOut(duration: 0.5)) {
                            proxy.scrollTo("top", anchor: .top)
                            showScrollToTop = false
                        }
                    }

                    // Sticky Bottom Buttons
                    VStack(spacing: 0) {
                        // Button container
                        HStack(spacing: 12) {
                            // Scroll to top button
                            if showScrollToTop {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.5)) {
                                        proxy.scrollTo("top", anchor: .top)
                                    }
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .foregroundColor(.white80)
                                        .frame(width: 40, height: 40)
                                        .background(Color.clear)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 30)
                                                .stroke(Color.white16, lineWidth: 2)
                                        )
                                        .cornerRadius(30)
                                }
                                .transition(.scale.combined(with: .opacity))
                            }

                            // Load More Button
                            if !addresses.isEmpty {
                                CustomButton(
                                    title: t("settings__addr__gen_20"),
                                    variant: .secondary,
                                    size: .small,
                                    isLoading: isLoading,
                                    shouldExpand: true
                                ) {
                                    await loadMoreAddresses()
                                }
                            }

                            // Check Balances Button
                            CustomButton(
                                title: t("settings__addr__check_balances"),
                                variant: .primary,
                                size: .small,
                                isLoading: isLoadingBalances,
                                shouldExpand: true
                            ) {
                                await checkBalances()
                            }
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await loadAddresses()
        }
    }

    private func loadAddresses() async {
        isLoading = true
        loadedCount = initialLoadCount

        do {
            let accountAddresses = try await CoreService.shared.utility.getAccountAddresses(
                walletIndex: walletIndex,
                isChange: selectedAddressType == .change,
                startIndex: 0,
                count: initialLoadCount
            )

            await MainActor.run {
                addresses = accountAddresses.unused
                // Select the first address by default
                if let firstAddr = accountAddresses.unused.first {
                    selectedAddress = firstAddr.address
                }
                isLoading = false
            }

            // Automatically check balances for newly loaded addresses
            await checkBalancesForNewAddresses(accountAddresses.unused.map(\.address))

        } catch {
            await MainActor.run {
                app.toast(type: .error, title: t("settings__addr__error_loading_title"), description: error.localizedDescription)
                isLoading = false
            }
        }
    }

    private func loadMoreAddresses() async {
        guard !isLoading else { return }

        isLoading = true
        let nextStartIndex = loadedCount

        do {
            let accountAddresses = try await CoreService.shared.utility.getAccountAddresses(
                walletIndex: walletIndex,
                isChange: selectedAddressType == .change,
                startIndex: nextStartIndex,
                count: loadMoreCount
            )

            await MainActor.run {
                addresses.append(contentsOf: accountAddresses.unused)
                loadedCount += loadMoreCount
                isLoading = false
            }

            // Automatically check balances for newly loaded addresses
            await checkBalancesForNewAddresses(accountAddresses.unused.map(\.address))

        } catch {
            await MainActor.run {
                app.toast(type: .error, title: t("settings__addr__error_loading_more_title"), description: error.localizedDescription)
                isLoading = false
            }
        }
    }

    private func checkBalances() async {
        guard !isLoadingBalances else { return }

        isLoadingBalances = true

        do {
            let addressStrings = addresses.map(\.address)
            let balances = try await CoreService.shared.utility.getMultipleAddressBalances(addresses: addressStrings)

            await MainActor.run {
                addressBalances = balances
                isLoadingBalances = false
                app.toast(type: .success, title: t("settings__addr__balances_updated_title"), description: t("settings__addr__balances_updated_description"))
            }
        } catch {
            await MainActor.run {
                app.toast(type: .error, title: t("settings__addr__error_checking_balances_title"), description: error.localizedDescription)
                isLoadingBalances = false
            }
        }
    }

    /// Check balances for specific new addresses without showing loading state or toast
    private func checkBalancesForNewAddresses(_ newAddresses: [String]) async {
        // Don't interfere if user is already checking balances manually
        guard !isLoadingBalances else { return }

        do {
            let balances = try await CoreService.shared.utility.getMultipleAddressBalances(addresses: newAddresses)

            await MainActor.run {
                // Merge new balances with existing ones
                for (address, balance) in balances {
                    addressBalances[address] = balance
                }
            }
        } catch {
            Logger.error("Failed to automatically check balances for new addresses: \(error)", context: "AddressViewer")
            // Silently fail for automatic balance checking
        }
    }
}

struct AddressRow: View {
    @EnvironmentObject var app: AppViewModel

    let index: Int
    let address: String
    let balance: UInt64?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CaptionText(
                "\(index): \(address)",
                textColor: isSelected ? .white : .textPrimary
            )
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer()

            // Balance (only show if available)
            if let balance {
                MoneyText(
                    sats: Int(balance),
                    size: .caption,
                    color: isSelected ? .white : .white80
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.brandAccent : Color.white08)
        .cornerRadius(8)
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            UIPasteboard.general.string = address
            Haptics.play(.copiedToClipboard)
            app.toast(type: .success, title: t("common__copied"), description: address)
        }
        .accessibilityIdentifier("Address-\(index)")
    }
}

#Preview {
    NavigationView {
        AddressViewer()
            .preferredColorScheme(.dark)
    }
}
