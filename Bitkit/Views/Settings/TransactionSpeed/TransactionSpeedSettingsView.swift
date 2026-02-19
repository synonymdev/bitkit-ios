import SwiftUI

struct TransactionSpeedSettingsRow: View {
    let speed: TransactionSpeed
    let isSelected: Bool
    let onSelect: () -> Void
    var customSetSpeed: String?
    var rangeOverride: String?

    private var rangeText: String {
        rangeOverride ?? speed.longRange
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Image(speed.iconName)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(speed.iconColor)
                    .frame(width: 32, height: 32)
                    .padding(.trailing, 16)

                VStack(alignment: .leading, spacing: 0) {
                    BodyMSBText(speed.longTitle, textColor: .textPrimary)
                    BodySSBText(rangeText, textColor: .textSecondary)
                }

                Spacer()

                if let customSetSpeed {
                    BodyMText(customSetSpeed, textColor: .textPrimary)
                        .padding(.trailing, 5)
                }

                if isSelected {
                    Image("checkmark")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.brandAccent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifierIfPresent(speed.feeKeyComponent)
    }
}

struct TransactionSpeedSettingsView: View {
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    /// When custom default fee rate is set, returns the tier-based range description (e.g. "± 10-20 minutes").
    private func customSpeedRange() -> String? {
        guard case let .custom(rate) = settings.defaultTransactionSpeed else { return nil }
        return TransactionSpeed.getFeeTierLocalized(feeRate: UInt64(rate), feeEstimates: feeEstimatesManager.estimates, variant: .longRange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__speed_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("settings__general__speed_default"))
                        .frame(height: 50)

                    VStack(spacing: 0) {
                        TransactionSpeedSettingsRow(
                            speed: .fast,
                            isSelected: settings.defaultTransactionSpeed == .fast,
                            onSelect: {
                                settings.defaultTransactionSpeed = .fast
                                navigation.navigateBack()
                            }
                        )

                        Divider()

                        TransactionSpeedSettingsRow(
                            speed: .normal,
                            isSelected: settings.defaultTransactionSpeed == .normal,
                            onSelect: {
                                settings.defaultTransactionSpeed = .normal
                                navigation.navigateBack()
                            }
                        )

                        Divider()

                        TransactionSpeedSettingsRow(
                            speed: .slow,
                            isSelected: settings.defaultTransactionSpeed == .slow,
                            onSelect: {
                                settings.defaultTransactionSpeed = .slow
                                navigation.navigateBack()
                            }
                        )

                        Divider()

                        TransactionSpeedSettingsRow(
                            speed: .custom(satsPerVByte: 1), // Placeholder
                            isSelected: settings.defaultTransactionSpeed.isCustom,
                            onSelect: {
                                navigation.navigate(.customSpeedSettings)
                            },
                            customSetSpeed: settings.defaultTransactionSpeed.customSetSpeed,
                            rangeOverride: customSpeedRange()
                        )
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task { await feeEstimatesManager.getEstimates() }
    }
}

#Preview {
    NavigationStack {
        TransactionSpeedSettingsView()
            .environmentObject(NavigationViewModel())
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(FeeEstimatesManager())
    }
    .preferredColorScheme(.dark)
}
