import SwiftUI

enum SendRoute: Hashable {
    case options
    case manual
    case scan
    case amount
    case utxoSelection
    case confirm
    case feeRate
    case feeCustom
    case tag
    case quickpay
    case success(String)
    case failure
    case lnurlPayAmount
    case lnurlPayConfirm
}

struct SendConfig {
    let initialRoute: SendRoute

    init(view: SendRoute = .options) {
        initialRoute = view
    }
}

struct SendSheetItem: SheetItem {
    let id: SheetID = .send
    let size: SheetSize = .large
    let initialRoute: SendRoute

    init(initialRoute: SendRoute = .options) {
        self.initialRoute = initialRoute
    }
}

struct SendSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var tagManager: TagManager

    let config: SendSheetItem

    @State private var navigationPath: [SendRoute] = []

    var body: some View {
        Sheet(id: .send, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: SendRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
        .onAppear {
            tagManager.clearSelectedTags()
            wallet.resetSendState(speed: settings.defaultTransactionSpeed)

            Task {
                do {
                    try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
                } catch {
                    Logger.error("Failed to set default fee rate: \(error)")
                }
            }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: SendRoute) -> some View {
        switch route {
        case .options:
            SendOptionsView(navigationPath: $navigationPath)
        case .manual:
            SendEnterManuallyView(navigationPath: $navigationPath)
        case .scan:
            ScannerView(showBackButton: true)
        case .amount:
            SendAmountView(navigationPath: $navigationPath)
        case .utxoSelection:
            SendUtxoSelectionView(navigationPath: $navigationPath)
        case .confirm:
            SendConfirmationView(navigationPath: $navigationPath)
        case .feeRate:
            SendFeeRate(navigationPath: $navigationPath)
        case .feeCustom:
            SendFeeCustom(navigationPath: $navigationPath)
        case .tag:
            SendTagScreen(navigationPath: $navigationPath)
        case .quickpay:
            SendQuickpay(navigationPath: $navigationPath)
        case let .success(paymentId):
            SendSuccess(paymentId: paymentId)
        case .failure:
            SendFailure()
        case .lnurlPayAmount:
            LnurlPayAmount(navigationPath: $navigationPath)
        case .lnurlPayConfirm:
            LnurlPayConfirm(navigationPath: $navigationPath)
        }
    }
}
