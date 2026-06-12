import SwiftUI

/// A view that displays when the user is offline.
struct OfflineSheetScreen: View {
    let title: String

    var body: some View {
        ZStack(alignment: .top) {
            SheetHeader(title: title, showBackButton: false)
                .padding(.horizontal, 16)

            OfflineConnectionContent()
        }
        .navigationBarHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .bottomSafeAreaPadding()
        .sheetBackground()
        .accessibilityIdentifier("ConnectionIssuesSheetScreen")
    }
}

// MARK: - View Modifier

private struct OfflineSheetOverlayModifier: ViewModifier {
    @EnvironmentObject private var network: NetworkMonitor

    let title: String
    var forceShow = false

    private var isShowing: Bool {
        !network.isConnected || forceShow
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content

            if isShowing {
                OfflineSheetScreen(title: title)
                    .transition(.opacity)

                // Custom drag indicator - always on top
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white32)
                    .frame(width: 32, height: 4)
                    .padding(.top, 12)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isShowing)
    }
}

extension View {
    /// Overlays a `OfflineSheetScreen` when the device is offline, or whenever `forceShow` is true
    /// (e.g. connection issues beyond device connectivity, like an unreachable Lightning peer).
    /// The underlying content remains mounted so navigation state and inputs are preserved.
    func offlineSheetOverlay(title: String, forceShow: Bool = false) -> some View {
        modifier(OfflineSheetOverlayModifier(title: title, forceShow: forceShow))
    }
}
