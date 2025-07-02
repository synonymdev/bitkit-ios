//
//  DisablePinView.swift
//  Bitkit
//
//  Created by Assistant on 2024/12/19.
//

import SwiftUI

struct DisablePinView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                BodyMText(
                    NSLocalizedString("security__pin_disable_text", comment: ""),
                    textColor: .textSecondary
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)

            Spacer()

            // Shield image
            Image("shield")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 274, height: 274)
                .padding(.top, 32)

            Spacer()

            // Disable PIN button
            CustomButton(
                title: NSLocalizedString("security__pin_disable_button", comment: ""),
                destination: PinCheckView(
                    title: NSLocalizedString("security__pin_enter", comment: ""),
                    explanation: "",
                    onCancel: {},
                    onPinVerified: { pin in
                        do {
                            try settings.removePin(pin: pin)
                            dismiss()
                        } catch {
                            Logger.error("Failed to remove PIN: \(error)", context: "DisablePinView")
                            // Still dismiss even if there's an error, as the PIN was verified
                            dismiss()
                        }
                    }
                )
            )
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .navigationTitle(NSLocalizedString("security__pin_disable_title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DisablePinView()
    }
    .preferredColorScheme(.dark)
    .environmentObject(SettingsViewModel())
}
