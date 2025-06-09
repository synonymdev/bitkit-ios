//
//  PinChangeView.swift
//  Bitkit
//
//  Created by Assistant on 2024/12/19.
//

import SwiftUI

//Used for changing the PIN or disabling it

struct PinChangeView: View {
    @State private var pinInput: String = ""
    @State private var firstPin: String = ""
    @State private var isConfirmingPin: Bool = false
    @State private var showSuccess: Bool = false
    @EnvironmentObject var settings: SettingsViewModel

    // Computed properties for title and description
    var title: String {
        if showSuccess {
            return "PIN Changed"
        } else {
            return "Set New PIN"
        }
    }

    var description: String {
        if showSuccess {
            return "You have successfully changed your PIN to a new 4-digit combination."
        } else if isConfirmingPin {
            return "Please repeat your PIN to confirm."
        } else {
            return "Please use a PIN you will remember. If you forget your PIN you can reset it, but that will require restoring your wallet."
        }
    }

    private func handlePinChange(_ pin: String) {
        // Handle PIN completion when 4 digits are entered
        if pin.count == 4 {
            Haptics.notify(.success)

            if !isConfirmingPin {
                // First PIN entry complete
                firstPin = pin
                isConfirmingPin = true
                pinInput = ""

                // Delay to show filled circles briefly before clearing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // PIN input is already cleared above
                }
            } else {
                // PIN confirmation
                if pin == firstPin {
                    // PINs match - show success
                    showSuccess = true
                    // TODO: Save PIN to settings
                } else {
                    // PINs don't match - reset
                    isConfirmingPin = false
                    firstPin = ""
                    pinInput = ""
                    // TODO: Show error message
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                BodyMText(description, textColor: .textSecondary)
                    .multilineTextAlignment(showSuccess ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: showSuccess ? .center : .leading)

                if !showSuccess {
                    // PIN input component - only show when not in success state
                    PinInput(pinInput: $pinInput) { pin in
                        handlePinChange(pin)
                    }
                    .padding(.bottom, 32)
                }

            }
            .padding(.horizontal, 16)

            Spacer()

        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Cancel") {
                    // TODO: Handle cancel action
                }
                .foregroundColor(.textPrimary)
            }
        }

    }
}

#Preview {
    NavigationStack {
        PinChangeView()
    }
    .preferredColorScheme(.dark)
    .environmentObject(SettingsViewModel())
}
