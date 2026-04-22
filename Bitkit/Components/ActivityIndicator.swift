import SwiftUI

struct ActivityIndicator: View {
    let size: CGFloat
    let theme: Theme

    enum Theme {
        case light
        case dark
    }

    @State private var isRotating = false
    @State private var opacity: Double = 0

    init(size: CGFloat = 32, theme: Theme = .light) {
        self.size = size
        self.theme = theme
    }

    var body: some View {
        let color = theme == .light ? Color.white : Color.black

        ZStack {
            Circle()
                .trim(from: 0.1, to: 0.94)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.clear, color]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isRotating)
        }
        .opacity(opacity)
        .onAppear {
            isRotating = true

            withAnimation(.easeInOut(duration: 1.0)) {
                opacity = 1.0
            }
        }
        .onDisappear {
            withAnimation(.easeInOut(duration: 1.0)) {
                opacity = 0.0
            }
        }
    }
}
