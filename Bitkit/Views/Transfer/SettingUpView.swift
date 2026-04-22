import BitkitCore
import SwiftUI

struct SettingUpView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    /// Keep in state so we don't get a new random text on each render
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

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(title, accentColor: .purpleAccent)
                    .padding(.bottom, 14)
                    .layoutPriority(1)

                BodyMText(text, accentColor: .white, accentFont: Fonts.bold)
                    .layoutPriority(1)

                if isTransferring {
                    EllipseLoader(variant: .transfer)
                        .padding(.top, 32)
                        .padding(.horizontal, 16)
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
                        .padding(.vertical, 16)
                }

                CustomButton(title: buttonTitle) {
                    navigation.reset()
                }
                .accessibilityIdentifier("TransferSuccess-button")
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onAppear {
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
