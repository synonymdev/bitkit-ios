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
    @State var order: IBtOrder
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel

    @State private var currentStep = 0
    @State private var isRocking = false
    private let randomOkText = LocalizedRandom("common__ok_random", comment: "")

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    let steps = [
        NSLocalizedString("lightning__setting_up_step1", comment: ""), // Processing Payment
        NSLocalizedString("lightning__setting_up_step2", comment: ""), // Payment Successful
        NSLocalizedString("lightning__setting_up_step3", comment: ""), // Queued For Opening
        NSLocalizedString("lightning__setting_up_step4", comment: ""), // Opening Connection
    ]

    func updateOrder(_ order: IBtOrder) async {
        if order.channel != nil {
            currentStep = 4
            return
        }

        if order.state2 == .created {
            currentStep = 0
        } else if order.state2 == .paid {
            currentStep = 1

            do {
                _ = try await blocktank.openChannel(orderId: order.id)
            } catch {
                Logger.error("Error opening channel: \(error)")
            }
        } else if order.state2 == .executed {
            currentStep = 2
        } else if order.channel != nil {
            currentStep = 3
        }

        print("currentStep:::::::::: \(currentStep)")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString(currentStep < 4 ? "lightning__savings_progress__title" : "lightning__transfer_success__title_spending", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                BodyMText(NSLocalizedString(currentStep < 4 ? "lightning__setting_up_text" : "lightning__transfer_success__text_spending", comment: ""), textColor: .textSecondary, accentColor: .white)
                    .padding(.bottom, 16)

                Spacer()

                if currentStep < 4 {
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

                if currentStep < 4 {
                    ProgressSteps(steps: steps, currentStep: currentStep)
                    Spacer()
                }

                CustomButton(
                    title: currentStep < 4 ? NSLocalizedString("lightning__setting_up_button", comment: "") : randomOkText,
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
        .navigationTitle(NSLocalizedString(currentStep < 4 ? "lightning__transfer__nav_title" : "lightning__transfer_success__nav_title", comment: ""))
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
            Logger.debug("View appeared - setting initial state and refreshing order")

            // Initial refresh
            Task {
                await updateOrder(order)

                if let refreshedOrder = try? await blocktank.refreshOrder(id: order.id) {
                    await updateOrder(refreshedOrder)
                }
            }
        }
        .onReceive(timer) { _ in
            Logger.debug("Timer fired - refreshing order")
            Task {
                if currentStep < 3, let refreshedOrder = try? await blocktank.refreshOrder(id: order.id) {
                    await updateOrder(refreshedOrder)
                }
            }
        }
    }
}

#Preview("Created") {
    NavigationView {
        SettingUpView(order: IBtOrder.mock(state2: .created))
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Paid") {
    NavigationView {
        SettingUpView(order: IBtOrder.mock(state2: .paid))
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Executed") {
    NavigationView {
        SettingUpView(order: IBtOrder.mock(state2: .executed))
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Opened") {
    NavigationView {
        SettingUpView(order: IBtOrder.mock(state2: .executed, channel: .mock()))
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
    }
    .preferredColorScheme(.dark)
}
