import SwiftUI

struct ProgressSteps: View {
    let steps: [String]
    let currentStep: Int

    var body: some View {
        VStack(spacing: 16) {
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
                    .stroke(style: StrokeStyle(
                        lineWidth: 1,
                        dash: [4, 4]
                    ))
                    .foregroundColor(Color.gray)

                    // Circles with numbers
                    HStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.0) { index, _ in
                            // Circle with number or checkmark
                            ZStack {
                                Circle()
                                    .fill(index < currentStep ? Color.purpleAccent : Color.black)
                                    .frame(width: 32, height: 32)

                                if index < currentStep {
                                    // Checkmark for completed steps
                                    Image("checkmark-black")
                                        .foregroundColor(.black)
                                        .font(.system(size: 14, weight: .bold))
                                } else {
                                    // Number for current and upcoming steps
                                    Text("\(index + 1)")
                                        .foregroundColor(index == currentStep ? Color.purpleAccent : .white32)
                                        .font(.system(size: 14, weight: .bold))
                                }

                                // Border for current step
                                if index == currentStep {
                                    Circle()
                                        .stroke(Color.purpleAccent, lineWidth: 2)
                                        .frame(width: 32, height: 32)
                                } else if index > currentStep {
                                    Circle()
                                        .stroke(Color.white32, lineWidth: 1)
                                        .frame(width: 32, height: 32)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }

            BodyMText(steps[currentStep], textColor: .textSecondary)
        }
    }
}

struct SettingUpView: View {
    @EnvironmentObject var app: AppViewModel

    @State private var currentStep = 2
    @State private var isRocking = false

    // TODO: keep refreshing BT order until it's open
    // Read from BlocktankViewModel. Maybe make that keep refreshing until it's open

    let steps = [
        NSLocalizedString("lightning__setting_up_step1", comment: ""),
        NSLocalizedString("lightning__setting_up_step2", comment: ""),
        NSLocalizedString("lightning__setting_up_step3", comment: ""),
        NSLocalizedString("lightning__setting_up_step4", comment: ""),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__savings_progress__title", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                BodyMText(NSLocalizedString("lightning__setting_up_text", comment: ""), textColor: .textSecondary, accentColor: .white)
                    .padding(.bottom, 16)

                Spacer()

                Image("hourglass")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: .infinity, height: 256)
                    .rotationEffect(.degrees(isRocking ? 25 : -25))
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isRocking)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        isRocking = true
                    }

                Spacer()

                ProgressSteps(steps: steps, currentStep: currentStep)

                Spacer()

                CustomButton(
                    title: NSLocalizedString("lightning__setting_up_button", comment: ""),
                    size: .large
                ) {
                    app.showFundingSheet = false
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
    }
}

#Preview {
    NavigationView {
        SettingUpView()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
