import BitkitCore
import SwiftUI

enum ReceiveRoute: Hashable {
    case usdt
    case qr(tab: ReceiveQr.ReceiveTab?)
    case edit(tab: ReceiveQr.ReceiveTab, onchainOnly: Bool)
    case tag
    case transferUnavailable
    case requestOrPay(publicKey: String)
    case paymentRequestRecipient(PaykitPaymentRequestDraft)
    case paymentRequestAmount(PaykitPaymentRequestDraft, PaykitPaymentRequestTarget)
    case paymentRequestDetails(PaykitPaymentRequestDraft, PaykitPaymentRequestTarget)
    case paymentRequestSent(PaykitPaymentRequest)

    var requiresInvoiceRefresh: Bool {
        switch self {
        case .qr, .edit, .tag, .transferUnavailable:
            return true
        case .usdt, .requestOrPay, .paymentRequestRecipient, .paymentRequestAmount, .paymentRequestDetails, .paymentRequestSent:
            return false
        }
    }
}

struct ReceiveConfig {
    let initialRoute: ReceiveRoute
    let hardwareWalletId: String?

    init(view: ReceiveRoute = .qr(tab: nil), hardwareWalletId: String? = nil) {
        initialRoute = view
        self.hardwareWalletId = hardwareWalletId
    }
}

struct ReceiveSheetItem: SheetItem {
    let id: UUID
    let size: SheetSize = .large
    let initialRoute: ReceiveRoute
    let hardwareWalletId: String?

    init(id: UUID = UUID(), initialRoute: ReceiveRoute = .qr(tab: nil), hardwareWalletId: String? = nil) {
        self.id = id
        self.initialRoute = initialRoute
        self.hardwareWalletId = hardwareWalletId
    }
}

struct ReceiveSheet: View {
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(TrezorManager.self) private var trezorManager

    let config: ReceiveSheetItem

    @State private var navigationPath: [ReceiveRoute] = []
    @State private var isUsdtSelected: Bool?

    private var usesUsdtHeader: Bool {
        switch navigationPath.last ?? config.initialRoute {
        case .usdt: isUsdtSelected ?? true
        case let .qr(tab): isUsdtSelected ?? (tab == .usdt)
        default: false
        }
    }

    var body: some View {
        Sheet(id: .receive, data: config, dragIndicatorInset: usesUsdtHeader ? 8 : 12) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: ReceiveRoute.self) { route in
                        viewForRoute(route)
                    }
            }
            .id(config.id)
        }
        .offlineSheetOverlay(title: t("wallet__receive"), isEnabled: config.initialRoute != .usdt)
        .sheet(isPresented: reconnectPairingBinding) {
            HardwarePairingSheet(config: HardwarePairingSheetItem())
        }
        .onAppear {
            navigationPath = []
            wallet.invoiceAmountSats = 0
            wallet.invoiceNote = ""
            tagManager.clearSelectedTags()
            guard config.initialRoute.requiresInvoiceRefresh else { return }
            Task {
                // Reset tags for current payment ID before refreshing
                try? await wallet.mutateReceiveTags(.reset)
                try? await wallet.refreshBip21(forceRefreshBolt11: true)
            }
        }
    }

    private var reconnectPairingBinding: Binding<Bool> {
        Binding(
            get: { trezorManager.showPairingCode },
            set: { isPresented in
                if !isPresented, trezorManager.showPairingCode {
                    trezorManager.cancelPairingCode()
                }
            }
        )
    }

    @ViewBuilder
    private func viewForRoute(_ route: ReceiveRoute) -> some View {
        switch route {
        case .usdt:
            ReceiveQr(navigationPath: $navigationPath, tab: .usdt, hardwareWalletId: config.hardwareWalletId,
                      onUsdtSelectionChange: { isUsdtSelected = $0 })
        case let .qr(tab):
            ReceiveQr(
                navigationPath: $navigationPath,
                tab: tab,
                hardwareWalletId: config.hardwareWalletId,
                onUsdtSelectionChange: { isUsdtSelected = $0 }
            )
        case let .edit(tab, onchainOnly):
            ReceiveEdit(navigationPath: $navigationPath, sourceTab: tab, onchainOnly: onchainOnly) { draft in
                navigationPath.append(.paymentRequestRecipient(draft))
            }
        case .tag:
            ReceiveTag(navigationPath: $navigationPath)
        case .transferUnavailable:
            ReceiveTransferUnavailable()
        case let .requestOrPay(publicKey):
            RequestOrPayView(publicKey: publicKey) { target in
                navigationPath.append(.paymentRequestAmount(Self.defaultPaymentRequestDraft, target))
            }
        case let .paymentRequestRecipient(draft):
            PaymentRequestRecipientView { target in
                if draft.amount.atomic == 0 {
                    navigationPath.append(.paymentRequestAmount(draft, target))
                } else {
                    navigationPath.append(.paymentRequestDetails(draft, target))
                }
            }
        case let .paymentRequestAmount(draft, target):
            PaymentRequestAmountView(initialDraft: draft, target: target) { updatedDraft in
                navigationPath.append(.paymentRequestDetails(updatedDraft, target))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("PaymentRequestAmount")
        case let .paymentRequestDetails(draft, target):
            PaymentRequestDetailsView(
                initialDraft: draft,
                target: target,
                onEditAmount: { updatedDraft in
                    if let route = navigationPath.last, case .paymentRequestDetails = route {
                        navigationPath.removeLast()
                    }
                    if let route = navigationPath.last, case .paymentRequestAmount = route {
                        navigationPath.removeLast()
                    }
                    navigationPath.append(.paymentRequestAmount(updatedDraft, target))
                },
                onSent: { request in
                    navigationPath.append(.paymentRequestSent(request))
                }
            )
        case let .paymentRequestSent(request):
            PaymentRequestSentView(request: request)
        }
    }

    static var defaultPaymentRequestDraft: PaykitPaymentRequestDraft {
        PaykitPaymentRequestDraft(
            amount: PaykitAmount(asset: .btc, atomic: 0),
            note: "",
            expiresAt: PaymentRequestExpiration.week.date(from: Date())
        )
    }
}
