import SwiftUI

enum BackupRoute: Hashable {
    case intro
    case mnemonic
    case passphrase(mnemonic: [String], passphrase: String)
    case confirmMnemonic(mnemonic: [String], passphrase: String)
    case confirmPassphrase(passphrase: String)
    case reminder
    case success
    case devices
    case metadata
}

struct BackupConfig {
    let initialRoute: BackupRoute

    init(view: BackupRoute = .intro) {
        self.initialRoute = view
    }
}

struct BackupSheetItem: SheetItem {
    let id: SheetID = .backup
    let size: SheetSize = .medium
    let initialRoute: BackupRoute

    init(initialRoute: BackupRoute = .intro) {
        self.initialRoute = initialRoute
    }
}

struct BackupSheet: View {
    @State private var navigationPath: [BackupRoute] = []
    let config: BackupSheetItem

    var body: some View {
        Sheet(id: .backup, data: config) {
            NavigationStack(path: $navigationPath) {
                viewForRoute(config.initialRoute)
                    .navigationDestination(for: BackupRoute.self) { route in
                        viewForRoute(route)
                    }
            }
        }
    }

    @ViewBuilder
    private func viewForRoute(_ route: BackupRoute) -> some View {
        switch route {
        case .intro:
            BackupIntroView(navigationPath: $navigationPath)
        case .mnemonic:
            BackupMnemonicView(navigationPath: $navigationPath)
        case .passphrase(let mnemonic, let passphrase):
            BackupPassphrase(navigationPath: $navigationPath, mnemonic: mnemonic, passphrase: passphrase)
        case .confirmMnemonic(let mnemonic, let passphrase):
            BackupConfirmMnemonic(navigationPath: $navigationPath, mnemonic: mnemonic, passphrase: passphrase)
        case .confirmPassphrase(let passphrase):
            BackupConfirmPassphrase(navigationPath: $navigationPath, passphrase: passphrase)
        case .reminder:
            BackupReminder(navigationPath: $navigationPath)
        case .success:
            BackupSuccess(navigationPath: $navigationPath)
        case .devices:
            BackupDevices(navigationPath: $navigationPath)
        case .metadata:
            BackupMetadata()
        }
    }
}
