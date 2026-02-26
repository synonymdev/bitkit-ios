import BitkitCore
import SwiftUI

struct HourglassLoadingView: View {
    @State private var rotation: Double = -16

    private var size: CGFloat { UIScreen.main.isSmall ? 160 : 256 }

    var body: some View {
        Image("hourglass")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .frame(maxWidth: .infinity)
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    rotation = 16
                }
            }
    }
}

struct SendPendingScreen: View {
    let paymentHash: String
    @Binding var navigationPath: [SendRoute]

    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var foundActivity: Activity?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_pending"), showBackButton: false)

            if let sendAmountSats = wallet.sendAmountSats {
                MoneyStack(sats: Int(sendAmountSats), showSymbol: true)
                    .padding(.bottom, 32)
            }

            BodyMText(t("wallet__send_pending_note"))

            Spacer()

            HourglassLoadingView()

            Spacer()

            HStack(spacing: 16) {
                CustomButton(
                    title: t("wallet__send_details"),
                    variant: .secondary,
                    isDisabled: foundActivity == nil
                ) {
                    if let foundActivity {
                        navigation.navigate(.activityDetail(foundActivity))
                        sheets.hideSheet()
                    }
                }

                CustomButton(title: t("common__close")) {
                    sheets.hideSheet()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await searchForActivity()
        }
        .onChange(of: app.sendSheetPendingResolution) { resolution in
            guard let resolution, resolution.paymentHash == paymentHash else { return }
            app.consumeSendSheetPendingResolution(paymentHash: paymentHash)
            if resolution.success {
                navigationPath.append(.success(paymentId: paymentHash))
            } else {
                navigationPath.append(.failure)
            }
        }
        .onDisappear {
            // Remove the pending payment hash from the app model when the screen disappears
            app.removePendingPaymentHash(paymentHash)
        }
    }

    private func searchForActivity() async {
        do {
            try? await activityList.syncLdkNodePayments()

            let activity = try await tryNTimes(
                toTry: { try await activityList.findActivity(byPaymentId: paymentHash) },
                times: 12,
                interval: 2
            )
            foundActivity = activity
        } catch {
            Logger.warn("Could not find activity for pending payment \(paymentHash): \(error)")
        }
    }
}
