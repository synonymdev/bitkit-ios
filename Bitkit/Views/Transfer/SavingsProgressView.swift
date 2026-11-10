import SwiftUI

enum SavingsProgressState: Equatable {
    case inProgress
    /// Swap hold invoice is paid but the on-chain claim has not landed within the wait window.
    /// The claim auto-broadcasts once the lockup appears, so the transfer is committed and settling.
    case settling
    case success
    case failed
    /// Spark's balance didn't move; `channelsMoved` when the selected channels still did.
    case sparkFailed(channelsMoved: Bool)
}

struct SavingsProgressContentView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    let progressState: SavingsProgressState

    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var transferRotation: Double = 0

    var navTitle: String {
        switch progressState {
        case .inProgress, .settling: return t("lightning__transfer__nav_title")
        case .failed: return t("lightning__savings_interrupted__nav_title")
        case .success: return t("lightning__transfer_success__nav_title")
        case .sparkFailed: return t("lightning__transfer__nav_title")
        }
    }

    var title: String {
        switch progressState {
        case .inProgress: return t("lightning__savings_progress__title")
        case .settling: return t("lightning__savings_settling__title")
        case .failed: return t("lightning__savings_interrupted__title")
        case .success: return t("lightning__transfer_success__title_savings")
        case .sparkFailed: return t("lightning__savings_spark_failed__title")
        }
    }

    var text: String {
        switch progressState {
        case .inProgress: return t("lightning__savings_progress__text")
        case .settling: return t("lightning__savings_settling__text")
        case .failed: return t("lightning__savings_interrupted__text")
        case .success: return t("lightning__transfer_success__text_savings")
        case let .sparkFailed(channelsMoved):
            return t(channelsMoved ? "lightning__savings_spark_failed__text_partial" : "lightning__savings_spark_failed__text")
        }
    }

    private var imageIdentifier: String? {
        switch progressState {
        case .success: "TransferSuccess"
        case .sparkFailed: "SavingsSparkFailed"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: navTitle, showBackButton: false)
                .padding(.bottom, 16)

            DisplayText(title, accentColor: .brandAccent)
                .padding(.bottom, 8)

            BodyMText(text, accentFont: Fonts.bold)

            Spacer()

            if progressState == .inProgress || progressState == .settling {
                ZStack(alignment: .center) {
                    // Outer ellipse
                    Image("ellipse-outer-brand")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 311, height: 311)
                        .rotationEffect(.degrees(outerRotation))

                    // Inner ellipse
                    Image("ellipse-inner-brand")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 207, height: 207)
                        .rotationEffect(.degrees(innerRotation))

                    // Transfer image
                    Image("transfer-figure")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .rotationEffect(.degrees(transferRotation))
                }
                .frame(width: 320, height: 320)
                .clipped()
                .frame(maxWidth: .infinity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                        outerRotation = -90
                    }

                    withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                        innerRotation = 120
                    }

                    withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                        transferRotation = 90
                    }
                }

            } else {
                Image(progressState == .success ? "check" : "exclamation-mark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifierIfPresent(imageIdentifier)
            }

            Spacer()

            if progressState != .inProgress {
                CustomButton(title: t("common__ok")) {
                    navigation.reset()
                }
                .accessibilityIdentifierIfPresent(imageIdentifier.map { "\($0)-button" })
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

struct SavingsProgressView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @State private var progressState: SavingsProgressState = .inProgress

    var body: some View {
        SavingsProgressContentView(progressState: progressState)
            .task {
                // Disable screen timeout while this view is active
                UIApplication.shared.isIdleTimerDisabled = true

                switch transfer.savingsTransferMode {
                case .swap:
                    await runSavingsSwap()
                case .close:
                    await runChannelClose()
                }
            }
            .onDisappear {
                // Ensure we re-enable screen timeout when view disappears
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }

    /// Swaps spending funds out to on-chain savings. A pending claim is shown as "settling"
    /// rather than success: the hold invoice is paid and the updates stream auto-claims it in
    /// the background, so the transfer is committed but not yet landed on-chain.
    private func runSavingsSwap() async {
        // Ensure the updates stream is running so the new swap is tracked and auto-claimed
        // once its lockup appears, even if the launch-time start had not yet succeeded.
        wallet.ensureSwapUpdatesRunning()

        let result = await transfer.executeSavingsSwap(
            onEvent: { id, handler in wallet.addOnEvent(id: id, handler: handler) },
            removeEvent: { id in wallet.removeOnEvent(id: id) }
        )
        UIApplication.shared.isIdleTimerDisabled = false

        switch result {
        case .success:
            await wallet.syncStateAsync()
            withAnimation {
                progressState = sparkFailedState(channelsMoved: true) ?? .success
            }
        case .pending:
            await wallet.syncStateAsync()
            withAnimation {
                progressState = sparkFailedState(channelsMoved: true) ?? .settling
            }
        case let .failure(message):
            app.toast(
                type: .error,
                title: t("common__error"),
                description: message
            )
            navigation.reset()
        }
    }

    /// The Spark failure state, with its error as a toast, when the transfer's Spark withdrawal failed.
    private func sparkFailedState(channelsMoved: Bool) -> SavingsProgressState? {
        guard transfer.sparkWithdrawError != nil else { return nil }
        toastSparkError()
        return .sparkFailed(channelsMoved: channelsMoved)
    }

    private func toastSparkError() {
        guard let message = transfer.sparkWithdrawError else { return }
        app.toast(type: .error, title: t("lightning__savings_spark_failed__toast"), description: message)
    }

    /// Legacy path: cooperatively close the selected channel(s), retrying on failure.
    private func runChannelClose() async {
        do {
            if transfer.hasChannelsToClose {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }

            let hadChannels = transfer.hasChannelsToClose
            let channelsFailedToCoopClose = try await transfer.closeSelectedChannels()
            let outcome = SavingsTransferOutcome.resolve(
                sparkFailed: transfer.sparkWithdrawError != nil,
                movedChannels: hadChannels,
                channelsFailedToClose: !channelsFailedToCoopClose.isEmpty
            )

            switch outcome {
            case .success:
                // Re-enable screen timeout when we're done
                UIApplication.shared.isIdleTimerDisabled = false

                withAnimation {
                    progressState = .success
                }
            case let .sparkFailed(channelsMoved):
                UIApplication.shared.isIdleTimerDisabled = false
                withAnimation {
                    progressState = sparkFailedState(channelsMoved: channelsMoved) ?? .success
                }
            case .channelsInterrupted:
                toastSparkError()
                withAnimation {
                    progressState = .failed
                }

                transfer.startCoopCloseRetries(channels: channelsFailedToCoopClose)
            }
        } catch {
            app.toast(error)
        }
    }
}

#Preview("In Progress") {
    NavigationStack {
        SavingsProgressContentView(progressState: .inProgress)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Settling") {
    NavigationStack {
        SavingsProgressContentView(progressState: .settling)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Success") {
    NavigationStack {
        SavingsProgressContentView(progressState: .success)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Spark Failed") {
    NavigationStack {
        SavingsProgressContentView(progressState: .sparkFailed(channelsMoved: true))
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Failed") {
    NavigationStack {
        SavingsProgressContentView(progressState: .failed)
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
