import BitkitCore
import Lottie
import SwiftUI

struct SweepSuccessView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var viewModel: SweepViewModel

    let txid: String

    private var confettiAnimation: LottieAnimation? {
        guard let filepathURL = Bundle.main.url(forResource: "confetti-orange", withExtension: "json") else {
            return nil
        }
        return LottieAnimation.filepath(filepathURL.path)
    }

    private var amountSwept: UInt64 {
        viewModel.sweepResult?.amountSwept ?? 0
    }

    var body: some View {
        ZStack {
            if let animation = confettiAnimation {
                LottieView(animation: animation)
                    .playing(loopMode: .loop)
                    .scaleEffect(1.9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 0) {
                NavigationBar(title: t("sweep__complete_title"))
                    .padding(.bottom, 16)

                BodyMText(t("sweep__complete_description"))
                    .foregroundColor(.textSecondary)
                    .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 16) {
                    MoneyText(sats: Int(amountSwept), unitType: .secondary, size: .caption, color: .textSecondary)
                    MoneyText(sats: Int(amountSwept), size: .display, symbol: true, symbolColor: .textSecondary)
                }

                Spacer()

                Image("check")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 256, height: 256)
                    .frame(maxWidth: .infinity)

                Spacer()

                CustomButton(title: t("sweep__wallet_overview")) {
                    navigation.reset()
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
    }
}
