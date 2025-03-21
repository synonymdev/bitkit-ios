import SwiftUI

struct SavingsIntroView: View {
    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "piggybank-right",
                title: NSLocalizedString("lightning__savings_intro__title", comment: ""),
                text: NSLocalizedString("lightning__savings_intro__text", comment: ""),
                accentColor: .brandAccent
            )

            NavigationLink(destination: Text("TODO")) {
                CustomButton(title: NSLocalizedString("lightning__savings_intro__button", comment: ""))
            }
        }
        .padding()
    }
}

#Preview {
    NavigationView {
        SavingsIntroView()
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
