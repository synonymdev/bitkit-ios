import SwiftUI
import WebKit

struct ShopMap: View {
    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                title: t("other__shop__discover__nav_title"),
                showMenuButton: false
            )

            ShopWebView(url: Env.btcMapUrl)
                .padding(.top, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}

#Preview {
    NavigationStack {
        ShopMap()
    }
    .preferredColorScheme(.dark)
}
