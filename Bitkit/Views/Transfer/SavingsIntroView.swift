import SwiftUI

struct SavingsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        OnboardingView(
            navTitle: t("lightning__transfer__nav_title"),
            title: t("lightning__savings_intro__title"),
            description: t("lightning__savings_intro__text"),
            imageName: "piggybank-right",
            buttonText: t("lightning__savings_intro__button"),
            onButtonPress: {
                app.hasSeenTransferToSavingsIntro = true
                navigation.navigateToTransferSavings(wallet: wallet, transfer: transfer)
            },
            imagePosition: .center,
            titleDescriptionSpacing: 8,
            contentHorizontalPadding: 0,
            maxImageSize: 256,
            testID: "SavingsIntro"
        )
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        SavingsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(WalletViewModel())
            .preferredColorScheme(.dark)
    }
}
