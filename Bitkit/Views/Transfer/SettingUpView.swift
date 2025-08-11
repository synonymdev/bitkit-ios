import BitkitCore
import SwiftUI

struct ProgressSteps: View {
    let steps: [String]
    let currentStep: Int

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
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: 1,
                            dash: [4, 4]
                        )
                    )
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
                                    Image("checkmark")
                                        .foregroundColor(.black)
                                } else {
                                    // Number for current and upcoming steps
                                    Text("\(index + 1)")
                                        .foregroundColor(index == currentStep ? Color.purpleAccent : .white32)
                                        .font(.custom(Fonts.regular, size: 17))
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
                    .padding(.bottom, 16)
                }
            }

            BodySSBText(steps[currentStep], textColor: .white32)
        }
    }
}

struct SettingUpView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var transferRotation: Double = 0
    // Keep in state so we don't get a new random text on each render
    @State private var randomOkText: String = localizedRandom("common__ok_random", comment: "")

    var isTransferring: Bool {
        return transfer.lightningSetupStep < 3
    }

    var navTitle: String {
        return isTransferring ? localizedString("lightning__transfer__nav_title") : localizedString("lightning__transfer_success__nav_title")
    }

    var title: String {
        return isTransferring ? localizedString("lightning__savings_progress__title") : localizedString("lightning__transfer_success__title_spending")
    }

    var text: String {
        return isTransferring ? localizedString("lightning__setting_up_text") : localizedString("lightning__transfer_success__text_spending")
    }

    var buttonTitle: String {
        return isTransferring ? localizedString("lightning__setting_up_button") : randomOkText
    }

    let steps = [
        localizedString("lightning__setting_up_step1"), // Processing Payment
        localizedString("lightning__setting_up_step2"), // Payment Successful
        localizedString("lightning__setting_up_step3"), // Queued For Opening
        localizedString("lightning__setting_up_step4"), // Opening Connection
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(title, accentColor: .purpleAccent)
                    .fixedSize(horizontal: false, vertical: true)

                BodyMText(text, accentColor: .white, accentFont: Fonts.bold)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if isTransferring {
                    ZStack(alignment: .center) {
                        // Outer ellipse
                        Image("ellipse-outer-purple")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 311, height: 311)
                            .rotationEffect(.degrees(outerRotation))

                        // Inner ellipse
                        Image("ellipse-inner-purple")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 207, height: 207)
                            .rotationEffect(.degrees(innerRotation))

                        // Transfer image
                        Image("transfer-figure")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 256, height: 256)
                            .rotationEffect(.degrees(transferRotation))
                    }
                    .frame(width: 320, height: 320)
                    .clipped()
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            outerRotation = -90
                        }

                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            innerRotation = 120
                        }

                        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                            transferRotation = 90
                        }
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

                if isTransferring {
                    ProgressSteps(steps: steps, currentStep: transfer.lightningSetupStep)
                        .padding(.bottom, 32)
                }

                CustomButton(title: buttonTitle) {
                    navigation.reset()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationTitle(navTitle)
        .backToWalletButton()
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .interactiveDismissDisabled()
    }
}

#Preview("Created") {
    NavigationStack {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject(
                {
                    let vm = TransferViewModel()
                    vm.onOrderCreated(order: IBtOrder.mock(state2: .created))
                    vm.lightningSetupStep = 0
                    return vm
                }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Paid") {
    NavigationStack {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject(
                {
                    let vm = TransferViewModel()
                    vm.onOrderCreated(order: IBtOrder.mock(state2: .paid))
                    vm.lightningSetupStep = 1
                    return vm
                }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Executed") {
    NavigationStack {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject(
                {
                    let vm = TransferViewModel()
                    vm.onOrderCreated(order: IBtOrder.mock(state2: .executed))
                    vm.lightningSetupStep = 2
                    return vm
                }())
    }
    .preferredColorScheme(.dark)
}

#Preview("Opened") {
    NavigationStack {
        SettingUpView()
            .environmentObject(AppViewModel())
            .environmentObject(
                {
                    let vm = TransferViewModel()
                    vm.onOrderCreated(order: IBtOrder.mock(state2: .executed, channel: .mock()))
                    vm.lightningSetupStep = 4
                    return vm
                }())
    }
    .preferredColorScheme(.dark)
}
