import Lottie
import SwiftUI

struct PaymentCelebration: View {
    let isOnchain: Bool
    let isReceived: Bool
    var confettiColor: Color?

    var body: some View {
        ZStack {
            LottieView(animation: .named(isOnchain ? "confetti-orange" : "confetti-purple"))
                .configure { animationView in
                    let keypath = AnimationKeypath(keypath: "**.Color")
                    if let confettiColor {
                        animationView.setValueProvider(ColorValueProvider(UIColor(confettiColor).lottieColorValue), keypath: keypath)
                    } else {
                        animationView.removeValueProvider(for: keypath)
                    }
                }
                .playing(loopMode: .loop)
                .scaleEffect(1.9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isReceived {
                Image("coins-received")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(y: 50)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
