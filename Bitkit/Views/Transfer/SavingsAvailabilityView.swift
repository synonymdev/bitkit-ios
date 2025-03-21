//
//  SavingsAvailabilityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct SavingsAvailabilityView: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                DisplayText(NSLocalizedString("lightning__availability__title", comment: ""), accentColor: .brandAccent)
                    .padding(.top, 32)

                BodyMText(NSLocalizedString("lightning__availability__text", comment: ""), textColor: .textSecondary)
                    .padding(.top, 8)

                Spacer()

                ZStack {
                    Image("exclamation-mark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)

                Spacer()

                HStack(spacing: 16) {
                    CustomButton(
                        title: NSLocalizedString("common__cancel", comment: ""),
                        variant: .secondary,
                        size: .large
                    ) {
                        app.showTransferToSavingsSheet = false
                    }

                    CustomButton(
                        title: NSLocalizedString("common__continue", comment: ""),
                        variant: .primary,
                        size: .large
                    ) {
                        // Continue action
                    }
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
    }
}

#Preview {
    NavigationView {
        SavingsAvailabilityView()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
