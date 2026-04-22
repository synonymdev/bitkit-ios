import SwiftUI

/// A view that displays a list of steps with circles and numbers.
struct ProgressSteps: View {
    let steps: [String]
    let currentStep: Int

    private let size: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            // Steps with circles and separators
            GeometryReader { geometry in
                ZStack(alignment: .center) {
                    // Dashed line background
                    Path { path in
                        let y = geometry.size.height / 2
                        let padding = 36.0 * 2.5 // Account for circle radius (16) + horizontal padding (20)
                        path.move(to: CGPoint(x: padding, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width - padding, y: y))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(Color.white32)

                    // Circles with numbers
                    HStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.0) { index, _ in
                            // Circle with number or checkmark
                            ZStack {
                                Circle()
                                    .fill(index < currentStep ? Color.purpleAccent : Color.black)
                                    .frame(width: size, height: size)

                                if index < currentStep {
                                    // Checkmark for completed steps
                                    Image("checkmark")
                                        .foregroundColor(.black)
                                } else {
                                    // Number for current and upcoming steps
                                    Text("\(index + 1)")
                                        .foregroundColor(index == currentStep ? Color.purpleAccent : .white32)
                                        .font(.custom(Fonts.regular, size: 17))
                                }

                                // Border for uncompleted steps
                                if index >= currentStep {
                                    Circle()
                                        .stroke(index == currentStep ? Color.purpleAccent : Color.white32, lineWidth: 1)
                                        .frame(width: size, height: size)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .frame(height: size)

            VStack {
                BodySSBText(steps[currentStep], textColor: .white32)
            }
            .frame(height: 56)
        }
    }
}
