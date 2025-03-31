import SwiftUI

struct SavingsIntroView: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "piggybank-right",
                title: NSLocalizedString("lightning__savings_intro__title", comment: ""),
                text: NSLocalizedString("lightning__savings_intro__text", comment: ""),
                accentColor: .brandAccent
            )

            NavigationLink(destination: SavingsAvailabilityView()) {
                CustomButton(title: NSLocalizedString("lightning__savings_intro__button", comment: ""))
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    app.hasSeenTransferToSavingsIntro = true
                })
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showTransferToSavingsSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        SavingsIntroView()
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
            .preferredColorScheme(.dark)
    }
}
