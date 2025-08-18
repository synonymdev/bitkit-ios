import SwiftUI

struct TransactionSpeedSettingsRow: View {
    let speed: TransactionSpeed
    let isSelected: Bool
    let onSelect: () -> Void
    var customSetSpeed: String? = nil

    var iconColor: Color {
        switch speed {
        case .custom:
            return .textSecondary
        default:
            return .brandAccent
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(speed.iconName)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(iconColor)
                    .frame(width: 32, height: 32)
                    .padding(.trailing, 16)

                VStack(alignment: .leading, spacing: 0) {
                    BodyMSBText(speed.displayTitle, textColor: .textPrimary)
                    BodySSBText(speed.displayDescription, textColor: .textSecondary)
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
    }
}

struct TransactionSpeedSettingsView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var showingCustomAlert = false
    @State private var customRate: String = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(localizedString("settings__general__speed_default"))
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 0) {
                    TransactionSpeedSettingsRow(
                        speed: .fast,
                        isSelected: settings.defaultTransactionSpeed == .fast,
                        onSelect: {
                            settings.defaultTransactionSpeed = .fast
                        }
                    )

                    Divider()

                    TransactionSpeedSettingsRow(
                        speed: .medium,
                        isSelected: settings.defaultTransactionSpeed == .medium,
                        onSelect: {
                            settings.defaultTransactionSpeed = .medium
                        }
                    )

                    Divider()

                    TransactionSpeedSettingsRow(
                        speed: .slow,
                        isSelected: settings.defaultTransactionSpeed == .slow,
                        onSelect: {
                            settings.defaultTransactionSpeed = .slow
                        }
                    )

                    Divider()

                    TransactionSpeedSettingsRow(
                        speed: .custom(satsPerVByte: 1), // Placeholder
                        isSelected: {
                            if case .custom = settings.defaultTransactionSpeed { true } else { false }
                        }(),
                        onSelect: {
                            navigation.navigate(.customSpeedSettings)
                        },
                        customSetSpeed: settings.defaultTransactionSpeed.customSetSpeed
                    )
                }
            }
        }
        .navigationTitle(localizedString("settings__general__speed_title"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        TransactionSpeedSettingsView()
            .environmentObject(SettingsViewModel())
    }
    .preferredColorScheme(.dark)
}
