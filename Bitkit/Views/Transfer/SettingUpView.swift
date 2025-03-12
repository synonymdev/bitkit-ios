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
    @EnvironmentObject var transfer: TransferViewModel

    @State private var isRocking = false
    @State private var randomOkText: String = LocalizedRandom("common__ok_random", comment: "") // Keep in state so we don't get a new random text on each render

    var isTransfering: Bool {
        return transfer.lightningSetupStep < 3
    }

    let steps = [
        NSLocalizedString("lightning__setting_up_step1", comment: ""), // Processing Payment
        NSLocalizedString("lightning__setting_up_step2", comment: ""), // Payment Successful
        NSLocalizedString("lightning__setting_up_step3", comment: ""), // Queued For Opening
        NSLocalizedString("lightning__setting_up_step4", comment: ""), // Opening Connection
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString(isTransfering ? "lightning__savings_progress__title" : "lightning__transfer_success__title_spending", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                BodyMText(NSLocalizedString(isTransfering ? "lightning__setting_up_text" : "lightning__transfer_success__text_spending", comment: ""), textColor: .textSecondary, accentColor: .white)
                    .padding(.bottom, 16)

                Spacer()

                if isTransfering {
                    Image("hourglass")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .rotationEffect(.degrees(isRocking ? 25 : -25))
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isRocking)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            isRocking = true
                        }
                } else {
                    Image("check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()

                if isTransfering {
                    ProgressSteps(steps: steps, currentStep: transfer.lightningSetupStep)
                    Spacer()
                }

                CustomButton(
                    title: isTransfering ? NSLocalizedString("lightning__setting_up_button", comment: "") : randomOkText,
                    size: .large
                ) {
                    app.showFundingSheet = false
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .navigationTitle(NSLocalizedString(transfer.lightningSetupStep < 4 ? "lightning__transfer__nav_title" : "lightning__transfer_success__nav_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showFundingSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            Logger.debug("View appeared - TransferViewModel is handling order updates")
        }
    }
}

#Preview("Created") {
    NavigationView {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject({
                let vm = TransferViewModel()
                vm.onOrderCreated(order: IBtOrder.mock(state2: .created))
                vm.lightningSetupStep = 0
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Paid") {
    NavigationView {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject({
                let vm = TransferViewModel()
                vm.onOrderCreated(order: IBtOrder.mock(state2: .paid))
                vm.lightningSetupStep = 1
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Executed") {
    NavigationView {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject({
                let vm = TransferViewModel()
                vm.onOrderCreated(order: IBtOrder.mock(state2: .executed))
                vm.lightningSetupStep = 2
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Opened") {
    NavigationView {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject({
                let vm = TransferViewModel()
                vm.onOrderCreated(order: IBtOrder.mock(state2: .executed, channel: .mock()))
                vm.lightningSetupStep = 4
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}
