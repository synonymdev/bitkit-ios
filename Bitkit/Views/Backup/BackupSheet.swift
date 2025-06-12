import SwiftUI

enum BackupView {
    case intro
    case main
}

struct BackupConfig {
    let initialView: BackupView

    init(view: BackupView = .intro) {
        self.initialView = view
    }
}

struct BackupSheetItem: SheetItem {
    let id: SheetID = .backup
    let size: SheetSize = .medium
    let initialView: BackupView

    init(initialView: BackupView = .intro) {
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
                case .intro:
                    BackupIntroView(config: config)
                case .main:
                    BackupMnemonicView()
                }
            }
        }
    }
}
