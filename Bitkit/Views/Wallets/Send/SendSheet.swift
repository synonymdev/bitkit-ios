import SwiftUI

enum SendRoute {
    case options
    case manual
    case amount
    case confirm
    case quickpay
    case success
}

struct SendConfig {
    let initialRoute: SendRoute

    init(view: SendRoute = .options) {
        self.initialRoute = view
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
    }

    @ViewBuilder
    private func viewForRoute(_ route: SendRoute) -> some View {
        switch route {
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
