import SwiftUI

enum SendView {
    case options
    case amount
    case confirm
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

    var body: some View {
        Sheet(id: .send, data: config) {
            NavigationStack {
                switch config.initialView {
                case .options:
                    SendOptionsView()
                case .amount:
                    SendAmountView()
                case .confirm:
                    SendConfirmationView()
                }
            }
        }
    }
}
