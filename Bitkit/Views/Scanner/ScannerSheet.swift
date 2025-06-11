import SwiftUI

struct ScannerSheetItem: SheetItem {
    let id: SheetID = .scanner
    let size: SheetSize = .large
}

struct ScannerSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    let config: ScannerSheetItem

    var body: some View {
        Sheet(id: .scanner, data: config) {
            // SheetHeader(title: localizedString("other__qr_scan"))

            ScannerView()
        }
    }
}
