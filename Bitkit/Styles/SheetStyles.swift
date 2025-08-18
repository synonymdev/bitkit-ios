import SwiftUI

extension View {
    /// Applies a standard dark gradient background for sheet views
    func sheetBackground() -> some View {
        background(
            LinearGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.012)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(Color.black)
    }
}
