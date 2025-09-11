import SwiftUI

enum RecoveryRoute: Hashable {
    case main
    case mnemonic
}

struct RecoveryRouter: View {
    @State private var navigationPath: [RecoveryRoute] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            viewForRoute(.main)
                .navigationDestination(for: RecoveryRoute.self) { route in
                    viewForRoute(route)
                }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: RecoveryRoute) -> some View {
        switch route {
        case .main:
            RecoveryScreen(navigationPath: $navigationPath)
        case .mnemonic:
            RecoveryMnemonicScreen(navigationPath: $navigationPath)
        }
    }
}
