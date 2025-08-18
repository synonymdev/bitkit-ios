import Lottie
import SwiftUI

struct ReceivedTxSheetItem: SheetItem {
    let id: SheetID = .receivedTx
    let size: SheetSize = .large
    let details: ReceivedTxSheetDetails
}

struct ReceivedTx: View {
    let config: ReceivedTxSheetItem

    @EnvironmentObject private var sheets: SheetViewModel

    // Keep in state so we don't get a new random text on each render
    @State private var buttonText: String = localizedRandom("common__ok_random")

    // Load the confetti animation
    private var confettiAnimation: LottieAnimation? {
        let isOnchain = config.details.type == .onchain
        let animationName = isOnchain ? "confetti-orange" : "confetti-purple"

        guard let filepathURL = Bundle.main.url(forResource: animationName, withExtension: "json") else {
            print("Could not find \(animationName).json in bundle")
            return nil
        }

        return LottieAnimation.filepath(filepathURL.path)
    }

    var body: some View {
        let isOnchain = config.details.type == .onchain
        let title = isOnchain ? t("wallet__payment_received") : t("wallet__instant_payment_received")

        Sheet(id: .receivedTx, data: config) {
            ZStack {
                if let animation = confettiAnimation {
                    LottieView(animation: animation)
                        .playing(loopMode: .loop)
                        // Scale the animation to fill the sheet
                        .scaleEffect(1.9)
                        .frame(width: .infinity, height: .infinity)
                }

                Image("coins-received")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(y: 50)

                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: title)
                    MoneyStack(sats: Int(config.details.sats), showSymbol: true)
                    Spacer()
                    CustomButton(title: buttonText) { sheets.hideSheet() }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                ReceivedTx(config: ReceivedTxSheetItem(details: ReceivedTxSheetDetails(type: .lightning, sats: 1000)))
                    .environmentObject(SheetViewModel())
            }
        )
        .presentationDetents([.height(UIScreen.screenHeight - 120)])
        .preferredColorScheme(.dark)
}
