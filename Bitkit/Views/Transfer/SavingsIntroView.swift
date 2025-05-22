import SwiftUI

struct SavingsIntroView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack {
            OnboardingContent(
                imageName: "piggybank-right",
                title: localizedString("lightning__savings_intro__title"),
                text: localizedString("lightning__savings_intro__text"),
                accentColor: .brandAccent
            )

            CustomButton(title: localizedString("lightning__savings_intro__button")) {
                app.hasSeenTransferToSavingsIntro = true
                navigation.navigate(.savingsAvailability)
            }
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        SavingsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
            .preferredColorScheme(.dark)
    }
}
