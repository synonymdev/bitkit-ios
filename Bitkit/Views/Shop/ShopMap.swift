import SwiftUI
import WebKit

struct ShopMap: View {
    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                title: t("other__shop__discover__nav_title"),
                showMenuButton: false
            )

            ShopMapContent()
                .padding(.top, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}

// MARK: - Shop Map Content

struct ShopMapContent: View {
    var body: some View {
        ShopWebView(url: Env.btcMapUrl)
    }
}

#Preview {
    NavigationStack {
        ShopMap()
    }
    .preferredColorScheme(.dark)
}
