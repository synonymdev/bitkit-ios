import BitkitCore
import SwiftUI

/// "Transaction signed" — a brief confirmation of the signed funding tx before auto-forwarding to
/// the shared "Funds in Transfer" progress screen.
struct SpendingHwSigned: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    /// Figma handoff delay before forwarding from the signed confirmation.
    private let autoForwardDelay: UInt64 = 1_000_000_000

    var body: some View {
        Group {
            if let order = transfer.uiState.order {
                content(order: transfer.displayOrder(for: order))
            } else {
                Color.clear.onAppear { navigation.reset() }
            }
        }
    }

    private func content(order: IBtOrder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer_hw__signed_title"), accentColor: .purpleAccent)

            SpendingHwFeeGrid(order: order)
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
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            try? await Task.sleep(nanoseconds: autoForwardDelay)
            guard !Task.isCancelled else { return }
            navigation.navigate(.settingUp)
        }
    }
}
