import SwiftUI

extension View {
    /// Applies a standard dark gradient background for sheet views
    func sheetBackground() -> some View {
        self
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.white64.opacity(0.15), Color.black]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .background(Color.black)
    }
} 