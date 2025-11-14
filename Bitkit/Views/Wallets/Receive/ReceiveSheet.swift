import BitkitCore
import SwiftUI

enum ReceiveRoute: Hashable {
    case qr(cjitInvoice: String?, tab: ReceiveQr.ReceiveTab?)
    case edit
    case tag
    case cjitAmount
    case cjitConfirm(entry: IcJitEntry, receiveAmountSats: UInt64, isAdditional: Bool)
    case cjitLearnMore(entry: IcJitEntry, receiveAmountSats: UInt64, isAdditional: Bool)
}

struct ReceiveConfig {
    let initialRoute: ReceiveRoute

    init(view: ReceiveRoute = .qr(cjitInvoice: nil, tab: nil)) {
        initialRoute = view
    }
}

struct ReceiveSheetItem: SheetItem {
    let id: SheetID = .receive
    let size: SheetSize = .large
    let initialRoute: ReceiveRoute

    init(initialRoute: ReceiveRoute = .qr(cjitInvoice: nil, tab: nil)) {
        self.initialRoute = initialRoute
    }
}

struct ReceiveSheet: View {
    let config: ReceiveSheetItem
    @State private var navigationPath: [ReceiveRoute] = []
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var tagManager: TagManager

    var body: some View {
        Sheet(id: .receive, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: ReceiveRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
        .onAppear {
            wallet.invoiceAmountSats = 0
            wallet.invoiceNote = ""
            tagManager.clearSelectedTags()
            Task {
                // Reset tags for current payment ID before refreshing
                if let paymentId = await wallet.paymentId(), !paymentId.isEmpty {
                    try? await CoreService.shared.activity.resetPreActivityMetadataTags(paymentId: paymentId)
                }
                try? await wallet.refreshBip21(forceRefreshBolt11: true)
            }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: ReceiveRoute) -> some View {
        switch route {
        case let .qr(cjitInvoice, tab):
            ReceiveQr(navigationPath: $navigationPath, cjitInvoice: cjitInvoice, tab: tab)
        case .edit:
            ReceiveEdit(navigationPath: $navigationPath)
        case .tag:
            ReceiveTag(navigationPath: $navigationPath)
        case .cjitAmount:
            ReceiveCjitAmount(navigationPath: $navigationPath)
        case let .cjitConfirm(entry, receiveAmountSats, isAdditional):
            ReceiveCjitConfirmation(navigationPath: $navigationPath, entry: entry, receiveAmountSats: receiveAmountSats, isAdditional: isAdditional)
        case let .cjitLearnMore(entry, receiveAmountSats, isAdditional):
            ReceiveCjitLearnMore(entry: entry, receiveAmountSats: receiveAmountSats, isAdditional: isAdditional)
        }
    }
}
