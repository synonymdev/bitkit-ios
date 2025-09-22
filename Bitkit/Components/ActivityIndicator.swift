import SwiftUI

struct ActivityIndicator: View {
    let size: CGFloat

    @State private var isRotating = false
    @State private var opacity: Double = 0

    init(size: CGFloat = 32) {
        self.size = size
    }

    var body: some View {
        let strokeWidth = size / 12

        ZStack {
            Circle()
                .trim(from: 0.1, to: 0.94)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.black, .white]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        lineCap: .round
                    )
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .animation(
                    .linear(duration: 1.2)
                        .repeatForever(autoreverses: false),
                    value: isRotating
                )
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
