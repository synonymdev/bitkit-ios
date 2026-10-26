import Lottie
import SwiftUI

struct PaymentCelebration: View {
    let isOnchain: Bool
    let isReceived: Bool
    var confettiColor: Color?
    var isUsdt = false

    var body: some View {
        ZStack {
            if isUsdt {
                Color.black.ignoresSafeArea(edges: .bottom)
            }

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

            if isUsdt {
                LinearGradient(colors: [Color(hex: 0x8E8E93).opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            }

            if isReceived {
                Image(isUsdt ? "usdt-coins-received" : "coins-received")
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
