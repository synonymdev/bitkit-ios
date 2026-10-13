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

            if isReceived, isUsdt {
                // The artwork includes overflow beyond Figma's centered 256pt frame.
                Image("usdt-coins-received")
                    .resizable()
                    .frame(width: 348.5, height: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .offset(x: 13.25, y: windowSafeAreaInsets.bottom - 36)
            } else if isReceived {
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
