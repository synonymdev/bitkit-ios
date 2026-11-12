import SwiftUI

/// What the transfer status screen shows: one per frame of the Funds In Transfer (spark) design.
enum SettingUpStage: Equatable {
    /// Spark has not seen the deposit yet; `normalSpeed` when it is added after 3 confirmations.
    case processing(normalSpeed: Bool)
    /// Spark has seen the deposit; `normalSpeed` when it is added after 3 confirmations.
    case received(normalSpeed: Bool)
    /// The fast transfer fee rose above what the user approved.
    case feeChanged(feeSats: UInt64)
    /// No fast transfer for this deposit, so it is added at normal speed.
    case fastUnavailable
    /// Spark is adding the deposit to the spending balance; `normalSpeed` once the user chose to wait.
    case adding(normalSpeed: Bool)
    /// The deposit reached the spending balance.
    case done

    /// `isSeen` once Spark lists the deposit. `approvedFee` once the user approved a changed fee, so the claim that
    /// follows doesn't step back to Received, and `hasWaited` once the user chose Wait over it.
    init(state: SparkClaimState, isSeen: Bool = false, approvedFee: Bool = false, hasWaited: Bool = false) {
        func seenOrProcessing(normalSpeed: Bool) -> SettingUpStage {
            isSeen ? .received(normalSpeed: normalSpeed) : .processing(normalSpeed: normalSpeed)
        }
        self = switch state {
        case .looking: approvedFee ? .adding(normalSpeed: false) : seenOrProcessing(normalSpeed: false)
        case .notSeen: seenOrProcessing(normalSpeed: true)
        case .later: hasWaited ? .adding(normalSpeed: true) : seenOrProcessing(normalSpeed: true)
        case .claiming: approvedFee ? .adding(normalSpeed: false) : .received(normalSpeed: false)
        case .adding: .adding(normalSpeed: false)
        case let .repriced(feeSats): .feeChanged(feeSats: feeSats)
        case .unavailable: .fastUnavailable
        case .added: .done
        }
    }

    /// The index of the step in progress.
    var currentStep: Int {
        switch self {
        case .processing: 0
        case .received: 1
        case .feeChanged, .fastUnavailable, .adding, .done: 2
        }
    }

    /// Processing Payment, Payment Successful, then what the last step is doing.
    var steps: [String] {
        let last = switch self {
        case .feeChanged: t("lightning__setting_up__step_fee_changed")
        case .fastUnavailable, .adding(normalSpeed: true): t("lightning__setting_up__step_normal_speed")
        default: t("lightning__setting_up_step_spark")
        }
        return [t("lightning__setting_up_step1"), t("lightning__setting_up_step2"), last]
    }

    var title: String {
        switch self {
        case .feeChanged: t("lightning__setting_up__fee_changed_title")
        case .fastUnavailable: t("lightning__setting_up__unavailable_title")
        case .done: t("lightning__transfer_success__title_spending")
        default: t("lightning__savings_progress__title")
        }
    }

    /// Whether the text says about 30 minutes rather than a few minutes.
    var isNormalSpeed: Bool {
        switch self {
        case .processing(normalSpeed: true), .received(normalSpeed: true), .adding(normalSpeed: true), .fastUnavailable: true
        default: false
        }
    }

    /// Coins while the fast transfer is in question, the transfer arrows otherwise.
    var showsCoins: Bool {
        switch self {
        case .feeChanged, .fastUnavailable: true
        default: false
        }
    }
}

struct SettingUpView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(SparkTransferFlow.self) private var flow

    @State private var approvedFee = false
    @State private var hasWaited = false

    private var stage: SettingUpStage {
        SettingUpStage(state: flow.claimState, isSeen: isDepositSeen, approvedFee: approvedFee, hasWaited: hasWaited)
    }

    private var isDepositSeen: Bool {
        guard let txid = flow.txid else { return false }
        return SparkManager.shared.deposits.contains { $0.isListed && $0.txid.caseInsensitiveCompare(txid) == .orderedSame }
    }

    var text: String {
        switch stage {
        case .done: t("lightning__transfer_success__text_spending")
        case let .feeChanged(feeSats):
            t("lightning__setting_up__fee_changed_text", variables: ["fee": currency.primaryAmountText(sats: feeSats)])
        default: stage.isNormalSpeed ? t("lightning__setting_up__text_normal") : t("lightning__setting_up__text_fast")
        }
    }

    var body: some View {
        let stage = stage
        VStack(spacing: 0) {
            NavigationBar(
                title: stage == .done ? t("lightning__transfer_success__nav_title") : t("lightning__transfer__nav_title"),
                showBackButton: false
            )
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(stage.title, accentColor: .purpleAccent)
                    .padding(.bottom, 8)
                    .layoutPriority(1)

                BodyMText(text, accentColor: .white, accentFont: Fonts.bold)
                    .layoutPriority(1)
                    .accessibilityIdentifier("SettingUpText")

                if stage == .done {
                    Image("check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // Drawn as in the design: 274pt, centred in a 256pt box 44pt below the text.
                        .frame(width: 274, height: 274)
                        .padding(.top, 35)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("TransferSuccess")
                } else {
                    EllipseLoader(variant: stage.showsCoins ? .quickpay : .transfer)
                        .id(stage.showsCoins)
                        .padding(.top, 32)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("LightningSettingUp")
                }

                Spacer()

                if stage != .done {
                    ProgressSteps(steps: stage.steps, currentStep: stage.currentStep)
                        .padding(.vertical, 16)
                }

                if case .feeChanged = stage {
                    feeChangedButtons
                } else {
                    CustomButton(title: stage == .done ? t("lightning__setting_up__success_button") : t("lightning__setting_up_button")) {
                        navigation.reset()
                    }
                    .accessibilityIdentifier("TransferSuccess-button")
                }
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        // Later and Wait run no claim of their own, so the deposit Spark claims at maturity ends the transfer.
        .onChange(of: SparkManager.shared.deposits, initial: true) { _, deposits in
            flow.noteSettled(deposits)
        }
    }

    private var feeChangedButtons: some View {
        HStack(spacing: 16) {
            CustomButton(title: t("lightning__spark_deposit__wait_button"), variant: .secondary) {
                hasWaited = true
                flow.waitForConfirmations()
            }
            .accessibilityIdentifier("SparkDepositWait")

            CustomButton(title: t("lightning__setting_up__approve")) {
                approvedFee = true
                flow.payRepriced()
            }
            .accessibilityIdentifier("SparkDepositPay")
        }
    }
}

#Preview("Processing") {
    settingUpPreview(.looking)
}

#Preview("Processing normal") {
    settingUpPreview(.later, speed: .later)
}

#Preview("Payment successful") {
    settingUpPreview(.claiming)
}

#Preview("Fee changed") {
    settingUpPreview(.repriced(feeSats: 2134))
}

#Preview("Fast unavailable") {
    settingUpPreview(.unavailable)
}

#Preview("Adding") {
    settingUpPreview(.adding)
}

#Preview("Done") {
    settingUpPreview(.added)
}

@MainActor
private func settingUpPreview(_ state: SparkClaimState, speed: SparkTransferSpeed = .instant) -> some View {
    NavigationStack {
        SettingUpView()
            .environmentObject(CurrencyViewModel())
            .environmentObject(NavigationViewModel())
            .environment(SparkTransferFlow(amountSats: 100_000, speed: speed, claimState: state))
    }
    .preferredColorScheme(.dark)
}
