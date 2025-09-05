import SwiftUI

struct BuyBitcoinView: View {
    var body: some View {
        OnboardingView(
            title: t("other__buy_header"),
            description: t("other__buy_text"),
            imageName: "bitcoin-emboss",
            buttonText: t("other__buy_button"),
            onButtonPress: {
                // TODO: hide card .buyBitcoin
                UIApplication.shared.open(URL(string: "https://bitcoin.org/en/exchanges")!)
            },
            imagePosition: .center,
            testID: "BuyBitcoin"
        )
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        BuyBitcoinView()
            .preferredColorScheme(.dark)
    }
}
