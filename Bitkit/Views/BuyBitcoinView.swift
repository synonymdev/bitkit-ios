import SwiftUI

struct BuyBitcoinView: View {
    var body: some View {
        OnboardingView(
            title: localizedString("other__buy_header"),
            description: localizedString("other__buy_text"),
            imageName: "bitcoin-emboss",
            buttonText: localizedString("other__buy_button"),
            onButtonPress: {
                // TODO: hide card .buyBitcoin
                UIApplication.shared.open(URL(string: "https://bitcoin.org/en/exchanges")!)
            },
            imagePosition: .center,
            testID: "BuyBitcoin"
        )
    }
}

#Preview {
    NavigationStack {
        BuyBitcoinView()
            .preferredColorScheme(.dark)
    }
}
