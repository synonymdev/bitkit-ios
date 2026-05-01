import SwiftUI

enum SecurityRoute: Hashable {
    case intro
    case setupPin
    case biometrics
    case noBiometrics
    case success
    case changePin
    case changePinSuccess
    case disablePin
}

struct SecurityConfig {
    let initialRoute: SecurityRoute

    init(initialRoute: SecurityRoute = .intro) {
        self.initialRoute = initialRoute
    }
}

struct SecuritySheetItem: SheetItem {
    let id: SheetID = .security
    let size: SheetSize = .medium
    let initialRoute: SecurityRoute

    init(initialRoute: SecurityRoute = .intro) {
        self.initialRoute = initialRoute
    }
}

struct SecuritySheet: View {
    @State private var navigationPath: [SecurityRoute] = []
    let config: SecuritySheetItem

    var body: some View {
        Sheet(id: .security, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
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
            SecurityIntro(navigationPath: $navigationPath)
        case .setupPin:
            SecuritySetupPin(navigationPath: $navigationPath)
        case .biometrics:
            SecurityBiometrics(navigationPath: $navigationPath)
        case .noBiometrics:
            SecurityNoBiometrics(navigationPath: $navigationPath)
        case .success:
            SecuritySuccess()
        case .changePin:
            SecurityChangePin(navigationPath: $navigationPath)
        case .changePinSuccess:
            SecurityChangePinSuccess()
        case .disablePin:
            SecurityDisablePin()
        }
    }
}
