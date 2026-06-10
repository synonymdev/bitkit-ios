import SwiftUI

/// A view that displays while the node is syncing.
/// Used as an overlay on screens that require the node to be fully synced.
struct SendSyncScreen: View {
    @EnvironmentObject var wallet: WalletViewModel

    /// Shows the "connection issues" copy instead of the initial connecting copy after a long wait
    let showLongWait: Bool

    /// Optional callback when sync completes
    var onSyncComplete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: t("wallet__send_bitcoin"), showBackButton: false)

                    Spacer()

                    VStack(spacing: 0) {
                        EllipseLoader(variant: .sync)

                        DisplayText(
                            t(showLongWait ? "wallet__send_sync_long_title" : "wallet__send_sync_title"),
                            accentColor: showLongWait ? .yellowAccent : .purpleAccent
                        )
                        .padding(.top, 32)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                        BodyMText(t(showLongWait ? "wallet__send_sync_long_description" : "wallet__send_sync_description"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }

                    HStack(alignment: .center) {
                        ActivityIndicator(size: 24)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                }
                .padding(.horizontal, 32)
            }
        }
        .navigationBarHidden(true)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: wallet.isSyncingWallet) { _, newValue in
            if !newValue {
                onSyncComplete?()
            }
        }
    }
}
