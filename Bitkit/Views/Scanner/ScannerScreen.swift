import SwiftUI

struct ScannerScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var scanner: ScannerManager
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    private var scannerContext: ScannerContext {
        if navigation.path.contains(.electrumSettings) {
            return .electrum
        }

        return .main
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("other__qr_scan"))

            Scanner(
                onScan: { uri in
                    await scanner.handleScan(uri, context: scannerContext)
                },
                onImageSelection: { item in
                    await scanner.handleImageSelection(item, context: scannerContext)
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
                await scanner.handlePaste(context: scannerContext)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
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
