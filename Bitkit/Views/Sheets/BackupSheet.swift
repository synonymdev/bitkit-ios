import SwiftUI

enum BackupView {
    case main
    case detail
}

struct BackupConfig {
    let initialView: BackupView

    init(view: BackupView = .main) {
        self.initialView = view
    }
}

struct BackupSheetItem: SheetItem {
    let id: SheetID = .backup
    let size: SheetSize = .medium
    let initialView: BackupView

    init(initialView: BackupView = .main) {
        self.initialView = initialView
    }
}

struct BackupSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    let config: BackupSheetItem

    var body: some View {
        Sheet(id: .backup, data: config) {
            NavigationStack {
                switch config.initialView {
                case .main:
                    BackupIntroView(config: config)
                case .detail:
                    BackupMnemonicView()
                }
            }
        }
    }
}
