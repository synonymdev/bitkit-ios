import SwiftUI

enum SendView {
    case options
    case manual
    case amount
    case confirm
    case quickpay
    case success
}

struct SendConfig {
    let initialView: SendView

    init(view: SendView = .options) {
        self.initialView = view
    }
}

struct SendSheetItem: SheetItem {
    let id: SheetID = .send
    let size: SheetSize = .large
    let initialView: SendView

    init(initialView: SendView = .options) {
        self.initialView = initialView
    }
}

struct SendSheet: View {
    let config: SendSheetItem
    @State private var navigationPath: [SendView] = []

    var body: some View {
        Sheet(id: .send, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForSendView(config.initialView)
                    .navigationDestination(for: SendView.self) { view in
                        viewForSendView(view)
                    }
            }
        }
    }

    @ViewBuilder
    private func viewForSendView(_ view: SendView) -> some View {
        switch view {
        case .options:
            SendOptionsView(navigationPath: $navigationPath)
        case .manual:
            SendEnterManuallyView(navigationPath: $navigationPath)
        case .amount:
            SendAmountView(navigationPath: $navigationPath)
        case .confirm:
            SendConfirmationView(navigationPath: $navigationPath)
        case .quickpay:
            SendQuickpay(navigationPath: $navigationPath)
        case .success:
            SendSuccess()
        }
    }
}
