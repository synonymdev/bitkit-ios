import SwiftUI

struct ScannerScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScannerView(isFullScreen: true)
        }
        .navigationTitle(t("other__qr_scan"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
        .bottomSafeAreaPadding()
    }
}
