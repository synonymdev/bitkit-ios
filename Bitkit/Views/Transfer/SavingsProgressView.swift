import SwiftUI

enum SavingsProgressState {
    case inProgress
    case success
    case failed
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
        case .inProgress: return t("lightning__transfer__nav_title")
        case .failed: return t("lightning__savings_interrupted__nav_title")
        case .success: return t("lightning__transfer__nav_title")
        }
    }

    var title: String {
        switch progressState {
        case .inProgress: return t("lightning__savings_progress__title")
        case .failed: return t("lightning__savings_interrupted__title")
        case .success: return t("lightning__transfer_success__title_savings")
        }
    }

    var text: String {
        switch progressState {
        case .inProgress: return t("lightning__savings_progress__text")
        case .failed: return t("lightning__savings_interrupted__text")
        case .success: return t("lightning__transfer_success__text_savings")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: navTitle)
                .padding(.bottom, 16)

            DisplayText(title, accentColor: .brandAccent)
                .padding(.bottom, 16)

            BodyMText(text, accentFont: Fonts.bold)

            Spacer()

            if progressState == .inProgress {
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
                Image(progressState == .failed ? "exclamation-mark" : "check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifierIfPresent(progressState == .success ? "TransferSuccess" : nil)
            }

            Spacer()

            CustomButton(
                title: t("common__ok"),
                isLoading: progressState == .inProgress
            ) {
                navigation.reset()
            }
            .accessibilityIdentifierIfPresent(progressState == .success ? "TransferSuccess-button" : nil)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .interactiveDismissDisabled()
    }
}

struct SavingsProgressView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @State private var progressState: SavingsProgressState = .inProgress

    var body: some View {
        SavingsProgressContentView(progressState: progressState)
            .task {
                // Disable screen timeout while this view is active
                UIApplication.shared.isIdleTimerDisabled = true

                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)

                    let channelsFailedToCoopClose = try await transfer.closeSelectedChannels()

                    if channelsFailedToCoopClose.isEmpty {
                        // Re-enable screen timeout when we're done
                        UIApplication.shared.isIdleTimerDisabled = false

                        withAnimation {
                            progressState = .success
                        }
                    } else {
                        // Check if any channels can be retried (filter out trusted peers)
                        let (_, nonTrustedChannels) = LightningService.shared.separateTrustedChannels(channelsFailedToCoopClose)

                        if nonTrustedChannels.isEmpty {
                            // All channels are trusted peers - show error and navigate back
                            UIApplication.shared.isIdleTimerDisabled = false
                            app.toast(
                                type: .error,
                                title: t("lightning__close_error"),
                                description: t("lightning__close_error_msg")
                            )
                            navigation.reset()
                        } else {
                            withAnimation {
                                progressState = .failed
                            }

                            // Start retrying the cooperative close for non-trusted channels
                            transfer.startCoopCloseRetries(channels: nonTrustedChannels)
                        }
                    }
                } catch {
                    app.toast(error)
                }
            }
            .onDisappear {
                // Ensure we re-enable screen timeout when view disappears
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: transfer.transferUnavailable) { unavailable in
                if unavailable {
                    transfer.transferUnavailable = false
                    app.toast(
                        type: .error,
                        title: t("lightning__close_error"),
                        description: t("lightning__close_error_msg")
                    )
                }
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

#Preview("Success") {
    NavigationStack {
        SavingsProgressContentView(progressState: .success)
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
