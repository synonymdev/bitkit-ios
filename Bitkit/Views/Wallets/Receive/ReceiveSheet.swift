import SwiftUI

struct ReceiveSheetItem: SheetItem {
    let id: SheetID = .receive
    let size: SheetSize = .large
}

struct ReceiveSheet: View {
    let config: ReceiveSheetItem

    var body: some View {
        Sheet(id: .receive, data: config) {
            NavigationStack {
                ReceiveView()
            }
        }
    }
}
