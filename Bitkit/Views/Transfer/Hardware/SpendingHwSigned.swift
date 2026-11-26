import SwiftUI

/// "Transaction signed" — a brief confirmation of the signed transfer before auto-forwarding to the shared
/// "Funds in Transfer" progress screen.
struct SpendingHwSigned: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(SparkTransferFlow.self) private var flow

    /// Figma handoff delay before forwarding from the signed confirmation.
    private let autoForwardDelay: Duration = .seconds(1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"), showBackButton: false)
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer_hw__signed_title"), accentColor: .purpleAccent)

            SpendingConfirmFees(quote: flow.quote, speed: flow.speed)
                .padding(.top, 16)

            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("HardwareTransferSigned")

            Spacer()
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            guard !SparkTransferFlow.isRunningInPreview else { return }
            try? await Task.sleep(for: autoForwardDelay)
            guard !Task.isCancelled else { return }
            navigation.navigate(.settingUp)
        }
    }
}

#Preview {
    NavigationStack {
        SpendingHwSigned()
            .environmentObject(CurrencyViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(SettingsViewModel.shared)
            .environment(SparkTransferFlow(amountSats: 100_000))
    }
    .preferredColorScheme(.dark)
}
