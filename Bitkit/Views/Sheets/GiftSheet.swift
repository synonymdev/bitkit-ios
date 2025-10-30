import SwiftUI

enum GiftRoute: Hashable {
    case loading(code: String, amount: Int)
    case used
    case usedUp
    case failed
}

struct GiftConfig {
    let code: String
    let amount: Int
}

struct GiftSheetItem: SheetItem {
    let id: SheetID = .gift
    let size: SheetSize = .large
    let code: String
    let amount: Int

    init(code: String, amount: Int) {
        self.code = code
        self.amount = amount
    }
}

struct GiftSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @State private var navigationPath: [GiftRoute] = []
    let config: GiftSheetItem

    var body: some View {
        Sheet(id: .gift, data: config) {
            NavigationStack(path: $navigationPath) {
                GiftLoading(navigationPath: $navigationPath, code: config.code, amount: config.amount)
                    .navigationDestination(for: GiftRoute.self) { route in
                        switch route {
                        case .loading:
                            GiftLoading(navigationPath: $navigationPath, code: config.code, amount: config.amount)
                        case .used:
                            GiftUsed(navigationPath: $navigationPath)
                        case .usedUp:
                            GiftUsedUp(navigationPath: $navigationPath)
                        case .failed:
                            GiftFailed(navigationPath: $navigationPath)
                        }
                    }
            }
        }
    }
}
