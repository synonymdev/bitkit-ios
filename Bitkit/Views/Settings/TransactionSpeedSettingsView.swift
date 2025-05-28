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
                    BodyMText(customSetSpeed, textColor: .textPrimary, textAlignment: .right)
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
    @EnvironmentObject var wallet: WalletViewModel
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
                        isSelected: wallet.defaultTransactionSpeed == .fast,
                        onSelect: {
                            wallet.defaultTransactionSpeed = .fast
                        }
                    )
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    TransactionSpeedSettingsRow(
                        speed: .medium,
                        isSelected: wallet.defaultTransactionSpeed == .medium,
                        onSelect: {
                            wallet.defaultTransactionSpeed = .medium
                        }
                    )
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    TransactionSpeedSettingsRow(
                        speed: .slow,
                        isSelected: wallet.defaultTransactionSpeed == .slow,
                        onSelect: {
                            wallet.defaultTransactionSpeed = .slow
                        }
                    )
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    TransactionSpeedSettingsRow(
                        speed: .custom(satsPerVByte: 1), // Placeholder
                        isSelected: {
                            if case .custom(_) = wallet.defaultTransactionSpeed {
                                return true
                            }
                            return false
                        }(),
                        onSelect: {
                            // Reset to empty string when opening the alert
                            customRate = ""
                            showingCustomAlert = true
                        },
                        customSetSpeed: wallet.defaultTransactionSpeed.customSetSpeed
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
                    wallet.defaultTransactionSpeed = .custom(satsPerVByte: rate)
                }
            }
        } message: {
            Text("Enter the custom fee rate (₿/vB)")
        }
        .onAppear {
            // Initialize customRate from current setting if it's custom
            if case .custom(let satsPerVByte) = wallet.defaultTransactionSpeed {
                customRate = String(satsPerVByte)
            }
        }
    }
}

#Preview {
    NavigationStack {
        TransactionSpeedSettingsView()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
