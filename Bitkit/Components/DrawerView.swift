import SwiftUI

struct DrawerView: View {
    var onClose: () -> Void
    @Binding var navigationPath: NavigationPath

    @State private var currentDragOffset: CGFloat = 0
    @State private var showBackdrop = false
    @State private var showMenu = false

    let menuItems: [(icon: String, label: String)] = [
        ("coins", "WALLET"),
        ("heartbeat", "ACTIVITY"),
        ("users", "CONTACTS"),
        ("user-square", "PROFILE"),
        ("stack", "WIDGETS"),
        ("storefront", "SHOP"),
        ("gear-six", "SETTINGS"),
    ]

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
                        ForEach(menuItems, id: \.label) { item in
                            if item.label == "WALLET" {
                                Button(action: closeMenu) {
                                    menuItemContent(item: item)
                                }
                            } else if item.label == "ACTIVITY" {
                                Button(action: {
                                    navigationPath.append("ACTIVITY")
                                    closeMenu()
                                }) {
                                    menuItemContent(item: item)
                                }
                            } else if item.label == "SETTINGS" {
                                Button(action: {
                                    navigationPath.append("SETTINGS")
                                    closeMenu()
                                }) {
                                    menuItemContent(item: item)
                                }
                            } else {
                                Button(action: {}) {
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
    private func menuItemContent(item: (icon: String, label: String)) -> some View {
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
        // TODO: Add app status variants (error, warning, success) with appropriate icons and animations
        HStack(spacing: 8) {
            Image("warning")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.redAccent)
            BodyMSBText("App Status", textColor: .redAccent)
        }
    }
}

#Preview {
    DrawerView(onClose: {}, navigationPath: .constant(NavigationPath()))
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
}
