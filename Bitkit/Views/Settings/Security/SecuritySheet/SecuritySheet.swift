import SwiftUI

enum SecurityRoute: Hashable {
    case intro
    case pin
    case biometrics
    case noBiometrics
    case success
}

struct SecurityConfig {
    let showLaterButton: Bool

    init(showLaterButton: Bool = false) {
        self.showLaterButton = showLaterButton
    }
}

struct SecuritySheetItem: SheetItem {
    let id: SheetID = .security
    let showLaterButton: Bool
    let size: SheetSize = .medium

    static let withLaterButton = SecuritySheetItem(showLaterButton: true)
    static let withoutLaterButton = SecuritySheetItem(showLaterButton: false)
}

struct SecuritySheet: View {
    @State private var navigationPath: [SecurityRoute] = []
    let config: SecuritySheetItem

    var body: some View {
        Sheet(id: .security, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(.intro)
                    .navigationDestination(for: SecurityRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: SecurityRoute) -> some View {
        switch route {
        case .intro:
            SecurityIntro(navigationPath: $navigationPath, showLaterButton: config.showLaterButton)
        case .pin:
            SecurityPin(navigationPath: $navigationPath)
        case .biometrics:
            SecurityBiometrics(navigationPath: $navigationPath)
        case .noBiometrics:
            SecurityNoBiometrics(navigationPath: $navigationPath)
        case .success:
            SecuritySuccess(navigationPath: $navigationPath)
        }
    }
}
