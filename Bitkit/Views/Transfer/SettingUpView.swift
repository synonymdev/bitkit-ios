import BitkitCore
import SwiftUI

struct SettingUpLoadingView: View {
    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var transferRotation: Double = 0

    var size: (container: CGFloat, image: CGFloat, inner: CGFloat) {
        let container: CGFloat = UIScreen.main.isSmall ? 200 : 320
        let image = container * 0.8
        let inner = container * 0.7

        return (container: container, image: image, inner: inner)
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Outer ellipse
            Image("ellipse-outer-purple")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.container, height: size.container)
                .rotationEffect(.degrees(outerRotation))

            // Inner ellipse
            Image("ellipse-inner-purple")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.inner, height: size.inner)
                .rotationEffect(.degrees(innerRotation))

            // Transfer image
            Image("transfer-figure")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.image, height: size.image)
                .rotationEffect(.degrees(transferRotation))
        }
        .frame(width: size.container, height: size.container)
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
    }
}

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
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(Color.white32)

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
                }
            }

            BodySSBText(steps[currentStep], textColor: .white32)
                .padding(.top, 16)
        }
    }
}

struct SettingUpView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    // Keep in state so we don't get a new random text on each render
    @State private var randomOkText: String = localizedRandom("common__ok_random")

    var isTransferring: Bool {
        return transfer.lightningSetupStep < 3
    }

    var navTitle: String {
        return isTransferring ? t("lightning__transfer__nav_title") : t("lightning__transfer_success__nav_title")
    }

    var title: String {
        return isTransferring ? t("lightning__savings_progress__title") : t("lightning__transfer_success__title_spending")
    }

    var text: String {
        return isTransferring ? t("lightning__setting_up_text") : t("lightning__transfer_success__text_spending")
    }

    var buttonTitle: String {
        return isTransferring ? t("lightning__setting_up_button") : randomOkText
    }

    let steps = [
        t("lightning__setting_up_step1"), // Processing Payment
        t("lightning__setting_up_step2"), // Payment Successful
        t("lightning__setting_up_step3"), // Queued For Opening
        t("lightning__setting_up_step4"), // Opening Connection
    ]

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: navTitle, showBackButton: false)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                DisplayText(title, accentColor: .purpleAccent)
                    .fixedSize(horizontal: false, vertical: true)

                BodyMText(text, accentColor: .white, accentFont: Fonts.bold)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if isTransferring {
                    SettingUpLoadingView()
                        .accessibilityIdentifier("LightningSettingUp")
                } else {
                    Image("check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("TransferSuccess")
                }

                Spacer()

                if isTransferring {
                    ProgressSteps(steps: steps, currentStep: transfer.lightningSetupStep)
                        .padding(.bottom, 16)
                }

                CustomButton(title: buttonTitle) {
                    navigation.reset()
                }
                .accessibilityIdentifier("TransferSuccess-button")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .interactiveDismissDisabled()
        .onAppear {
            Logger.debug("View appeared - TransferViewModel is handling order updates")

            // Auto-mine a block in regtest mode after a 5-second delay
            if Env.network == .regtest {
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)

                    do {
                        Logger.debug("Auto-mining a block", context: "SettingUpView")
                        try await CoreService.shared.blocktank.regtestMineBlocks(1)
                        Logger.debug("Successfully mined a block", context: "SettingUpView")
                    } catch {
                        Logger.error("Failed to mine block: \(error.localizedDescription)", context: "SettingUpView")
                    }
                }
            }
        }
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
                }()
            )
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
                }()
            )
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
                }()
            )
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
                }()
            )
    }
    .preferredColorScheme(.dark)
}
