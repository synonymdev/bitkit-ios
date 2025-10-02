import SwiftUI

// Custom splash screen overlay - provides smooth fade transition from launch screen
// while wallet data loads. Fades out after 0.2s and removes after 0.4s.

struct SplashView: View {
    var body: some View {
        GeometryReader { geometry in
            Image("Splash")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .ignoresSafeArea()
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
