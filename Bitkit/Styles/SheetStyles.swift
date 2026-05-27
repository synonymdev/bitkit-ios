import SwiftUI

extension View {
    /// Applies the standard sheet gradient over the given base color. Default base is black;
    /// the v61 widgets sheet uses gray7.
    func sheetBackground(base: Color = .black) -> some View {
        background(
            LinearGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.012)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(base)
    }
}
