import SwiftUI

struct TabBar: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var shouldShow: Bool {
        if navigation.activeDrawerMenuItem == .wallet || navigation.activeDrawerMenuItem == .activity {
            if navigation.path.isEmpty {
                return true
            }

            switch navigation.currentRoute {
            case .activityList, .savingsWallet, .spendingWallet:
                return true
            default:
                return false
            }
        }

        return false
    }

    var body: some View {
        VStack {
            Spacer()

            if shouldShow {
                HStack(spacing: 0) {
                    TabBarButton(title: t("wallet__send"), icon: "arrow-up", variant: .left) {
                        onSendPress()
                    }

                    TabBarButton(title: t("wallet__receive"), icon: "arrow-down", variant: .right) {
                        onReceivePress()
                    }
                }
                .overlay {
                    ScanButton {
                        onScanPress()
                    }
                }
                .padding(.horizontal)
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut, value: shouldShow)
        .ignoresSafeArea(.keyboard)
        .bottomSafeAreaPadding()
    }

    private func onSendPress() {
        sheets.showSheet(.send)
    }

    private func onReceivePress() {
        let hasInboundCapacity = (wallet.totalInboundLightningSats ?? 0) > 0
        let hasPendingTransfersToSpending = wallet.balanceInTransferToSpending > 0

        if navigation.currentRoute == .spendingWallet && !hasInboundCapacity && !hasPendingTransfersToSpending {
            // On spending wallet screen, show CJIT flow when user can't receive normally
            sheets.showSheet(.receive, data: ReceiveConfig(view: .cjitAmount))
        } else {
            sheets.showSheet(.receive)
        }
    }

    private func onScanPress() {
        sheets.showSheet(.scanner)
    }
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
            .environmentObject(NavigationViewModel())
            .environmentObject(SheetViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
            .environmentObject(NavigationViewModel())
            .environmentObject(SheetViewModel())
    }
    .preferredColorScheme(.light)
}
