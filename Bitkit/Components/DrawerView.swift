import SwiftUI

struct DrawerView: View {
    var onClose: () -> Void
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var currentDragOffset: CGFloat = 0
    @State private var showBackdrop = false
    @State private var showMenu = false
    
    enum MenuItem: String, CaseIterable, Identifiable {
        case wallet
        case activity
        case contacts
        case profile
        case widgets
        // case shop
        case settings
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .wallet: return "coins"
            case .activity: return "heartbeat"
            case .contacts: return "users"
            case .profile: return "user-square"
            case .widgets: return "stack"
            // case .shop: return "storefront"
            case .settings: return "gear-six"
            }
        }
        
        var label: String {
            switch self {
            case .wallet: return NSLocalizedString("wallet__drawer__wallet", comment: "").uppercased()
            case .activity: return NSLocalizedString("wallet__drawer__activity", comment: "").uppercased()
            case .contacts: return NSLocalizedString("wallet__drawer__contacts", comment: "").uppercased()
            case .profile: return NSLocalizedString("wallet__drawer__profile", comment: "").uppercased()
            case .widgets: return NSLocalizedString("wallet__drawer__widgets", comment: "").uppercased()
            // case .shop: return "SHOP"
            case .settings: return NSLocalizedString("wallet__drawer__settings", comment: "").uppercased()
            }
        }
        
        var destination: String {
            switch self {
            case .wallet: return "WALLET"
            case .activity: return "ACTIVITY"
            case .contacts: return "CONTACTS"
            case .profile: return "PROFILE"
            case .widgets: return "WIDGETS"
            // case .shop: return "SHOP"
            case .settings: return "SETTINGS"
            }
        }
    }

    private func closeMenu() {
        showMenu = false
        withAnimation(.easeOut(duration: 0.25)) {
            showBackdrop = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onClose()
        }
    }
    
    @ViewBuilder
    private var backdrop: some View {
        Color.black.opacity(0.6)
            .ignoresSafeArea()
            .onTapGesture {
                closeMenu()
            }
            .transition(.opacity)
    }

    var body: some View {
        ZStack {
            if showBackdrop {
                backdrop
            }

            if showMenu {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(MenuItem.allCases) { item in
                            switch item {
                            case .wallet:
                                Button(action: closeMenu) {
                                    menuItemContent(item: item)
                                }
                            case .activity:
                                Button(action: {
                                    navigationPath.append(item.destination)
                                    closeMenu()
                                }) {
                                    menuItemContent(item: item)
                                }
                            case .settings:
                                Button(action: {
                                    navigationPath.append(item.destination)
                                    closeMenu()
                                }) {
                                    menuItemContent(item: item)
                                }
                            default:
                                Button(action: {
                                    app.toast(
                                        type: .info,
                                        title: "Coming Soon"
                                    )
                                    closeMenu()
                                }) {
                                    menuItemContent(item: item)
                                }
                            }
                        }
                        Spacer()
                        appStatus()
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }
                    .frame(width: geometry.size.width * 0.5, height: geometry.size.height)
                    .sheetBackground()
                    .offset(x: currentDragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                currentDragOffset = max(0, value.translation.width)
                            }
                            .onEnded { value in
                                let drawerWidth = geometry.size.width * 0.5
                                let closeCompletionThreshold = drawerWidth - 100

                                if currentDragOffset > closeCompletionThreshold {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        currentDragOffset = drawerWidth
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        closeMenu()
                                    }
                                } else {
                                    withAnimation(.easeOut) {
                                        currentDragOffset = 0
                                    }
                                }
                            }
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .onAppear {
            currentDragOffset = 0
            withAnimation(.easeOut(duration: 0.25)) {
                showBackdrop = true
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                showMenu = true
            }
        }
    }

    @ViewBuilder
    private func menuItemContent(item: MenuItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(item.icon)
                    .resizable()
                    .foregroundColor(.brandAccent)
                    .frame(width: 24, height: 24)
                Text(item.label)
                    .font(.custom(Fonts.black, size: 24))
                    .foregroundColor(.white)
                    .kerning(-1)
                    .padding(.vertical, 18)
            }
            .frame(height: 56)

            Divider()
                .background(Color.white.opacity(0.1))
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func appStatus() -> some View {
        HStack(spacing: 8) {
            Image(wallet.nodeLifecycleState.statusIcon)
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(wallet.nodeLifecycleState.statusColor)
            BodyMSBText(NSLocalizedString("settings__status__title", comment: ""), textColor: wallet.nodeLifecycleState.statusColor)
        }
    }
}

#Preview {
    DrawerView(onClose: {}, navigationPath: .constant(NavigationPath()))
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
}
