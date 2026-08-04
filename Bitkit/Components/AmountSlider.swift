import SwiftUI

/// Continuous slider over a `minValue`...`maxValue` range, styled to match `CustomSlider`
/// (same track and thumb) but without discrete steps. Used to pick a transfer amount
/// within its allowed limits.
struct AmountSlider: View {
    @Binding var value: UInt64
    let minValue: UInt64
    let maxValue: UInt64

    @State private var sliderWidth: CGFloat = 0

    private var fraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        let clamped = min(max(value, minValue), maxValue)
        return CGFloat(clamped - minValue) / CGFloat(maxValue - minValue)
    }

    private func value(at position: CGFloat) -> UInt64 {
        guard sliderWidth > 0, maxValue > minValue else { return minValue }
        let normalized = min(max(position / sliderWidth, 0), 1)
        return minValue + UInt64((Double(maxValue - minValue) * Double(normalized)).rounded())
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 32)
            .overlay(
                ZStack {
                    // Track background
                    Rectangle()
                        .fill(Color.green32)
                        .frame(height: 8)
                        .cornerRadius(8)

                    // Active track (from start to current position)
                    Rectangle()
                        .fill(Color.greenAccent)
                        .frame(width: fraction * sliderWidth, height: 8)
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Slider thumb
                    Circle()
                        .fill(Color.greenAccent)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 16, height: 16)
                        )
                        .position(x: fraction * sliderWidth, y: 16)
                        .allowsHitTesting(false)
                }
            )
            .contentShape(Rectangle())
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            sliderWidth = geometry.size.width
                        }
                        .onChange(of: geometry.size.width) { _, width in
                            sliderWidth = width
                        }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard sliderWidth > 0 else { return }
                        value = value(at: gesture.location.x)
                    }
            )
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var value: UInt64 = 72000

        var body: some View {
            VStack {
                AmountSlider(value: $value, minValue: 50000, maxValue: 100_000)
                Text("\(value) sats")
            }
            .padding(32)
        }
    }

    return PreviewWrapper()
        .preferredColorScheme(.dark)
}
