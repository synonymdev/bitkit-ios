import SwiftUI

struct ScannerScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // NavigationBar(title: t("other__qr_scan"))
            //     .padding(.horizontal, 16)

            ScannerView(isFullScreen: true)
        }
        // .navigationBarHidden(true)
        .navigationTitle(t("other__qr_scan"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomSafeAreaPadding()
    }
}
