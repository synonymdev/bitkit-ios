import Lottie
import SwiftUI

struct SendSuccess: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel

    // Load the confetti animation
    private var confettiAnimation: LottieAnimation? {
        let isOnchain = app.selectedWalletToPayFrom == .onchain
        let animationName = isOnchain ? "confetti-orange" : "confetti-purple"

        guard let filepathURL = Bundle.main.url(forResource: animationName, withExtension: "json") else {
            print("Could not find \(animationName).json in bundle")
            return nil
        }

        return LottieAnimation.filepath(filepathURL.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // Background confetti animation
                if let animation = confettiAnimation {
                    LottieView(animation: animation)
                        .playing(loopMode: .loop)
                        // Scale the animation to fill the sheet
                        .scaleEffect(1.9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: localizedString("wallet__send_sent"), showBackButton: false)

                    if let invoice = app.scannedLightningInvoice {
                        MoneyStack(sats: Int(invoice.amountSatoshis))
                    }

                    Spacer()

                    Image("check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer()

                    HStack(spacing: 16) {
                        CustomButton(title: localizedString("wallet__send_details"), variant: .secondary) {
                            // TODO: navigate to activity details screen
                        }

                        CustomButton(title: localizedString("common__close")) {
                            sheets.hideSheet()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationBarHidden(true)
            .sheetBackground()
        }
    }
}
