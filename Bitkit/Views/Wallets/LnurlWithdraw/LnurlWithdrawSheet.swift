import SwiftUI

enum LnurlWithdrawRoute: Hashable {
    case amount
    case confirm
    case failure(amount: UInt64)
}

struct LnurlWithdrawConfig {
    let initialRoute: LnurlWithdrawRoute

    init(view: LnurlWithdrawRoute = .amount) {
        initialRoute = view
    }
}

struct LnurlWithdrawSheetItem: SheetItem {
    let id: SheetID = .lnurlWithdraw
    let size: SheetSize = .large
    let initialRoute: LnurlWithdrawRoute

    init(initialRoute: LnurlWithdrawRoute = .amount) {
        self.initialRoute = initialRoute
    }
}

struct LnurlWithdrawSheet: View {
    let config: LnurlWithdrawSheetItem
    @State private var navigationPath: [LnurlWithdrawRoute] = []

    var body: some View {
        Sheet(id: .lnurlWithdraw, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: LnurlWithdrawRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: LnurlWithdrawRoute) -> some View {
        switch route {
        case .amount:
            LnurlWithdrawAmount(navigationPath: $navigationPath)
        case .confirm:
            LnurlWithdrawConfirm(navigationPath: $navigationPath)
        case let .failure(amount):
            LnurlWithdrawFailure(navigationPath: $navigationPath, amount: amount)
        }
    }
}
