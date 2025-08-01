import SwiftUI

struct TransactionSpeedSettingsRow: View {
    let speed: TransactionSpeed
    let isSelected: Bool
    let onSelect: () -> Void
    var customSetSpeed: String? = nil

    var iconColor: Color {
        switch speed {
        case .custom(_):
            return .white
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
                    .frame(width: 28, height: 28)
                    .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 4) {
                    BodyMText(speed.displayTitle, textColor: .textPrimary)
                    CaptionText(speed.displayDescription, textColor: .textSecondary)
                }

                Spacer()

                if let customSetSpeed {
                    BodyMText(customSetSpeed, textColor: .textPrimary)
                        .padding(.trailing, 8)
                }

                if isSelected {
                    Image("checkmark")
                        .foregroundColor(.brandAccent)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct TransactionSpeedSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @State private var showingCustomAlert = false
    @State private var customRate: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(NSLocalizedString("settings__general__speed_default", comment: "").uppercased())
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 0) {
                    TransactionSpeedSettingsRow(
                        speed: .fast,
                        isSelected: settings.defaultTransactionSpeed == .fast,
                        onSelect: {
                            settings.defaultTransactionSpeed = .fast
                        }
                    )
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    TransactionSpeedSettingsRow(
                        speed: .medium,
                        isSelected: settings.defaultTransactionSpeed == .medium,
                        onSelect: {
                            settings.defaultTransactionSpeed = .medium
                        }
                    )
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    TransactionSpeedSettingsRow(
                        speed: .slow,
                        isSelected: settings.defaultTransactionSpeed == .slow,
                        onSelect: {
                            settings.defaultTransactionSpeed = .slow
                        }
                    )
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    TransactionSpeedSettingsRow(
                        speed: .custom(satsPerVByte: 1), // Placeholder
                        isSelected: {
                            if case .custom(_) = settings.defaultTransactionSpeed {
                                return true
                            }
                            return false
                        }(),
                        onSelect: {
                            // Reset to empty string when opening the alert
                            customRate = ""
                            showingCustomAlert = true
                        },
                        customSetSpeed: settings.defaultTransactionSpeed.customSetSpeed
                    )
                    .padding(.horizontal, 16)
                }
            }
        }
        .navigationTitle("Transaction Speed")
        .alert("Custom Fee Rate", isPresented: $showingCustomAlert) {
            TextField("", text: $customRate)
                .keyboardType(.numberPad)

            Button("OK") {
                // Only proceed if a value was entered and it's valid
                if !customRate.isEmpty, let rate = UInt32(customRate), rate > 0 {
                    settings.defaultTransactionSpeed = .custom(satsPerVByte: rate)
                }
            }
        } message: {
            Text("Enter the custom fee rate (₿/vB)")
        }
        .onAppear {
            // Initialize customRate from current setting if it's custom
            if case .custom(let satsPerVByte) = settings.defaultTransactionSpeed {
                customRate = String(satsPerVByte)
            }
        }
    }
}

#Preview {
    NavigationStack {
        TransactionSpeedSettingsView()
            .environmentObject(SettingsViewModel())
    }
    .preferredColorScheme(.dark)
}
