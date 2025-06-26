import SwiftUI

struct CustomSlider: View {
    @Binding var value: Double
    let steps: [Double]

    @State private var sliderIndex: Double = 0
    @State private var sliderWidth: CGFloat = 0

    private func position(for index: Int) -> CGFloat {
        guard sliderWidth > 0, steps.count > 1 else { return 0 }
        return CGFloat(index) / CGFloat(steps.count - 1) * sliderWidth
    }

    var body: some View {
        VStack(spacing: 4) {
            // Custom container with overflow handling
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
                            .frame(
                                width: sliderWidth > 0 ? (sliderIndex / Double(steps.count - 1)) * sliderWidth : 0,
                                height: 8
                            )
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Step markers
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white)
                                .frame(width: 4, height: 16)
                                .position(
                                    x: position(for: index),
                                    y: 16
                                )
                        }

                        // Slider thumb with proper positioning
                        Circle()
                            .fill(Color.greenAccent)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 16, height: 16)
                            )
                            .position(
                                x: sliderWidth > 0 ? (sliderIndex / Double(steps.count - 1)) * sliderWidth : 0,
                                y: 16
                            )
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
                            .onChange(of: geometry.size.width) { width in
                                sliderWidth = width
                            }
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard sliderWidth > 0 else { return }
                            let position = max(0, min(sliderWidth, gesture.location.x))
                            let normalizedPosition = position / sliderWidth
                            let newIndex = normalizedPosition * Double(steps.count - 1)
                            sliderIndex = max(0, min(Double(steps.count - 1), newIndex))
                        }
                        .onEnded { _ in
                            // Snap to nearest step with animation
                            let roundedIndex = sliderIndex.rounded()
                            let targetIndex = max(0, min(Double(steps.count - 1), roundedIndex))

                            withAnimation(.easeOut(duration: 0.2)) {
                                sliderIndex = targetIndex
                            }

                            let index = Int(targetIndex)
                            if index >= 0 && index < steps.count {
                                value = steps[index]
                            }
                        }
                )
                .onAppear {
                    // Set initial slider position based on current value
                    if let index = steps.firstIndex(of: value) {
                        sliderIndex = Double(index)
                    }
                }
                .onChange(of: value) { newValue in
                    // Update slider position when value changes externally with animation
                    if let index = steps.firstIndex(of: newValue) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            sliderIndex = Double(index)
                        }
                    }
                }

            // Step labels
            GeometryReader { geometry in
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("$\(Int(step))")
                        .font(.custom(Fonts.medium, size: 13))
                        .foregroundColor(.textPrimary)
                        .position(
                            x: CGFloat(index) / CGFloat(steps.count - 1) * geometry.size.width,
                            y: geometry.size.height / 2
                        )
                }
            }
            .frame(height: 20)
        }
    }
}
