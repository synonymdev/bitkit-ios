import BitkitCore
import Lottie
import SwiftUI

struct SendSuccess: View {
    @EnvironmentObject var activityListViewModel: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let paymentId: String // The payment hash or txid from the successful payment

    @State private var foundActivity: Activity?

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
                    SheetHeader(title: t("wallet__send_sent"), showBackButton: false)

                    if let sendAmountSats = wallet.sendAmountSats {
                        MoneyStack(sats: Int(sendAmountSats), showSymbol: true)
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
                        CustomButton(
                            title: t("wallet__send_details"),
                            variant: .secondary,
                            isDisabled: foundActivity == nil
                        ) {
                            navigation.navigate(.activityDetail(foundActivity!))
                            sheets.hideSheet()
                        }

                        CustomButton(title: t("common__close")) {
                            sheets.hideSheet()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationBarHidden(true)
            .sheetBackground()
        }
        .task {
            await searchForActivity()
        }
    }

    private func searchForActivity() async {
        do {
            let activity = try await tryNTimes(
                toTry: {
                    try await activityListViewModel.findActivity(byPaymentId: paymentId)
                },
                times: 12,
                interval: 5
            )

            foundActivity = activity
        } catch {
            Logger.warn("Could not find activity for payment ID: \(paymentId) after 12 attempts")
        }
    }
}
