import SwiftUI

/// A view that displays when the user is offline.
struct OfflineScreen: View {
    let title: String

    var body: some View {
        ZStack(alignment: .top) {
            NavigationBar(title: title, showBackButton: true)
                .padding(.horizontal, 16)

            OfflineConnectionContent()
        }
        .navigationBarHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .bottomSafeAreaPadding()
        .background(Color.black)
        .accessibilityIdentifier("ConnectionIssuesScreen")
    }
}

// MARK: - View Modifier

private struct OfflineOverlayModifier: ViewModifier {
    @EnvironmentObject private var network: NetworkMonitor

    let title: String

    func body(content: Content) -> some View {
        ZStack {
            content

            if !network.isConnected {
                OfflineScreen(title: title)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: network.isConnected)
    }
}

extension View {
    /// Overlays a `OfflineScreen` when the device is offline.
    /// The underlying content remains mounted so navigation state and inputs are preserved.
    func offlineOverlay(title: String) -> some View {
        modifier(OfflineOverlayModifier(title: title))
    }
}
