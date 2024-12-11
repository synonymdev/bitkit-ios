import SwiftUI

struct SplashView: View {
    var body: some View {
        Image("Splash")
            .resizable()
            .scaledToFill()
            .offset(x: -4, y: -6)
            .scaleEffect(0.99)
            .ignoresSafeArea()
    }
}

#Preview {
    SplashView()
}
