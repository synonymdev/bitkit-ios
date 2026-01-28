import SwiftUI

/// Animated loading view with rotating ellipses and lightning icon
private struct SyncNodeLoadingView: View {
    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0

    var size: (container: CGFloat, image: CGFloat, inner: CGFloat) {
        let container: CGFloat = UIScreen.main.isSmall ? 200 : 320
        let image = container * 0.8
        let inner = container * 0.7

        return (container: container, image: image, inner: inner)
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Outer ellipse
            Image("ellipse-outer-purple")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.container, height: size.container)
                .rotationEffect(.degrees(outerRotation))

            // Inner ellipse
            Image("ellipse-inner-purple")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.inner, height: size.inner)
                .rotationEffect(.degrees(innerRotation))

            // Lightning image
            Image("lightning")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.image, height: size.image)
        }
        .frame(width: size.container, height: size.container)
        .clipped()
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                outerRotation = -90
            }

            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                innerRotation = 120
            }
        }
    }
}

/// A view that displays while the node is syncing.
/// Used as an overlay on screens that require the node to be fully synced.
struct SyncNodeView: View {
    @EnvironmentObject var wallet: WalletViewModel

    /// Optional callback when sync completes
    var onSyncComplete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_bitcoin"), showBackButton: false)

            VStack(spacing: 0) {
                BodyMText(t("lightning__wait_text_top"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)

                Spacer()

                SyncNodeLoadingView()

                Spacer()

                BodyMSBText(t("lightning__wait_text_bottom"), textColor: .white32)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: wallet.isSyncingWallet) { newValue in
            if !newValue {
                onSyncComplete?()
            }
        }
    }
}
