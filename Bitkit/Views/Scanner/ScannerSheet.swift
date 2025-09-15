import SwiftUI

struct ScannerSheetItem: SheetItem {
    let id: SheetID = .scanner
    let size: SheetSize = .large
}

struct ScannerSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var scanner: ScannerManager
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    let config: ScannerSheetItem

    var body: some View {
        Sheet(id: .scanner, data: config) {
            VStack(spacing: 0) {
                SheetHeader(title: t("other__qr_scan"))

                VStack(alignment: .leading, spacing: 0) {
                    Scanner(
                        onScan: { uri in
                            await scanner.handleScan(uri, context: .main)
                        },
                        onImageSelection: { item in
                            await scanner.handleImageSelection(item, context: .main)
                        }
                    )
                    .padding(.bottom, 16)

                    CustomButton(
                        title: t("other__qr_paste"),
                        icon: Image("clipboard")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                    ) {
                        await scanner.handlePaste(context: .main)
                    }
                }
            }
            .navigationBarHidden(false)
            .sheetBackground()
            .padding(.horizontal, 16)
            .onAppear {
                scanner.configure(
                    app: app,
                    currency: currency,
                    settings: settings,
                    navigation: navigation,
                    sheets: sheets
                )
            }
        }
    }
}
