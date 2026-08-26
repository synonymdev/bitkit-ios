import BitkitCore
import SwiftUI

enum ReceiveRoute: Hashable {
    case qr(cjitInvoice: String?, tab: ReceiveQr.ReceiveTab?)
    case edit(onchainOnly: Bool)
    case tag
    case cjitAmount
    case cjitConfirm(entry: IcJitEntry, receiveAmountSats: UInt64, isAdditional: Bool)
    case cjitLearnMore(entry: IcJitEntry, receiveAmountSats: UInt64, isAdditional: Bool)
    case cjitGeoBlocked
    case requestOrPay(publicKey: String)
    case paymentRequestRecipient(PaykitPaymentRequestDraft)
    case paymentRequestAmount(PaykitPaymentRequestDraft, PaykitPaymentRequestTarget)
    case paymentRequestDetails(PaykitPaymentRequestDraft, PaykitPaymentRequestTarget)
    case paymentRequestSent(PaykitPaymentRequest)
}

struct ReceiveConfig {
    let initialRoute: ReceiveRoute
    let hardwareWalletId: String?

    init(view: ReceiveRoute = .qr(cjitInvoice: nil, tab: nil), hardwareWalletId: String? = nil) {
        initialRoute = view
        self.hardwareWalletId = hardwareWalletId
    }
}

struct ReceiveSheetItem: SheetItem {
    let id: SheetID = .receive
    let size: SheetSize = .large
    let initialRoute: ReceiveRoute
    let hardwareWalletId: String?

    init(initialRoute: ReceiveRoute = .qr(cjitInvoice: nil, tab: nil), hardwareWalletId: String? = nil) {
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

    var body: some View {
        Sheet(id: .receive, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: ReceiveRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
        .offlineSheetOverlay(title: t("wallet__receive_bitcoin"))
        .sheet(isPresented: reconnectPairingBinding) {
            HardwarePairingSheet(config: HardwarePairingSheetItem())
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
        case let .qr(cjitInvoice, tab):
            ReceiveQr(
                navigationPath: $navigationPath,
                cjitInvoice: cjitInvoice,
                tab: tab,
                hardwareWalletId: config.hardwareWalletId
            )
        case let .edit(onchainOnly):
            ReceiveEdit(navigationPath: $navigationPath, onchainOnly: onchainOnly) { draft in
                navigationPath.append(.paymentRequestRecipient(draft))
            }
        case .tag:
            ReceiveTag(navigationPath: $navigationPath)
        case .cjitAmount:
            ReceiveCjitAmount(navigationPath: $navigationPath)
        case let .cjitConfirm(entry, receiveAmountSats, isAdditional):
            ReceiveCjitConfirmation(navigationPath: $navigationPath, entry: entry, receiveAmountSats: receiveAmountSats, isAdditional: isAdditional)
        case let .cjitLearnMore(entry, receiveAmountSats, isAdditional):
            ReceiveCjitLearnMore(entry: entry, receiveAmountSats: receiveAmountSats, isAdditional: isAdditional)
        case .cjitGeoBlocked:
            ReceiveCjitGeoBlocked()
        case let .requestOrPay(publicKey):
            RequestOrPayView(publicKey: publicKey) { target in
                navigationPath.append(.paymentRequestAmount(Self.defaultPaymentRequestDraft, target))
            }
        case let .paymentRequestRecipient(draft):
            PaymentRequestRecipientView { target in
                if draft.amountSats == 0 {
                    navigationPath.append(.paymentRequestAmount(draft, target))
                } else {
                    navigationPath.append(.paymentRequestDetails(draft, target))
                }
            }
        case let .paymentRequestAmount(draft, target):
            PaymentRequestAmountView(initialDraft: draft, target: target) { updatedDraft in
                navigationPath.append(.paymentRequestDetails(updatedDraft, target))
            }
        case let .paymentRequestDetails(draft, target):
            PaymentRequestDetailsView(
                initialDraft: draft,
                target: target,
                onEditAmount: { updatedDraft in
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
            amountSats: 0,
            note: "",
            expiresAt: PaymentRequestExpiration.week.date(from: Date())
        )
    }
}
