import SwiftUI

// TODO: maybe move to a separate file
enum DrawerMenuItem: Int, CaseIterable, Identifiable, Hashable {
    case wallet
    case activity
    case contacts
    case profile
    case widgets
    case shop
    case settings
    case appStatus

    var id: Int { rawValue }

    var icon: String {
        switch self {
        case .wallet: return "coins"
        case .activity: return "activity"
        case .contacts: return "users"
        case .profile: return "user-square"
        case .widgets: return "stack"
        case .shop: return "storefront"
        case .settings: return "gear-six"
        case .appStatus: return "status-circle"
        }
    }

    var label: String {
        switch self {
        case .wallet: return t("wallet__drawer__wallet")
        case .activity: return t("wallet__drawer__activity")
        case .contacts: return t("wallet__drawer__contacts")
        case .profile: return t("wallet__drawer__profile")
        case .widgets: return t("wallet__drawer__widgets")
        case .shop: return t("wallet__drawer__shop")
        case .settings: return t("wallet__drawer__settings")
        case .appStatus: return t("settings__status__title")
        }
    }

    var isMainMenuItem: Bool {
        switch self {
        case .appStatus:
            return false
        default:
            return true
        }
    }
}

struct DrawerView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var currentDragOffset: CGFloat = 0
    @State private var showBackdrop = false
    @State private var showMenu = false

    private func closeMenu() {
        withAnimation(.easeOut(duration: 0.25)) {
            showBackdrop = false
            showMenu = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            app.showDrawer = false
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
                        ForEach(DrawerMenuItem.allCases.filter(\.isMainMenuItem)) { item in
                            Button(action: {
                                navigation.reset()
                                navigation.activeDrawerMenuItem = item
                                closeMenu()
                            }) {
                                menuItemContent(item: item)
                            }
                        }

                        Spacer()

                        appStatus()
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }
                    .frame(width: geometry.size.width * 0.5, height: geometry.size.height)
                    .background(Color.brandAccent)
                    .offset(x: currentDragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                currentDragOffset = max(0, value.translation.width)
                            }
                            .onEnded { _ in
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
        .onChange(of: app.showDrawer) { show in
            if show {
                currentDragOffset = 0
                withAnimation(.easeOut(duration: 0.25)) {
                    showBackdrop = true
                }
                withAnimation(.easeOut(duration: 0.25).delay(0.1)) {
                    showMenu = true
                }
            }
        }
    }

    @ViewBuilder
    private func menuItemContent(item: DrawerMenuItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(item.icon)
                    .resizable()
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                Text(item.label.uppercased())
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
        Button {
            navigation.activeDrawerMenuItem = .appStatus
            closeMenu()
        } label: {
            HStack(spacing: 8) {
                Image(wallet.nodeLifecycleState.statusIcon)
                    .resizable()
                    .foregroundColor(.black)
                    .frame(width: 24, height: 24)
                BodyMSBText(DrawerMenuItem.appStatus.label, textColor: .black)
            }
        }
    }
}

#Preview {
    DrawerView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
}
