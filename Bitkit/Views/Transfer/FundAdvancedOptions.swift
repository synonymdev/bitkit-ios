//
//  FundAdvancedOptions.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/05/21.
//

import SwiftUI

struct FundAdvancedOptions: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Title
                    DisplayText(
                        NSLocalizedString("lightning__funding_advanced__title", comment: ""),
                        accentColor: .purpleAccent
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Description
                    BodyMText(NSLocalizedString("lightning__funding_advanced__text", comment: ""))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Options
                    VStack(spacing: 8) {
                        NavigationLink(destination: ScannerView()) {
                            RectangleButton(
                                icon: Image("scan")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.purpleAccent),
                                title: NSLocalizedString("lightning__funding_advanced__button1", comment: "")
                            )
                        }

                        NavigationLink(destination: FundManualSetupView()) {
                            RectangleButton(
                                icon: Image("pencil")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.purpleAccent),
                                title: NSLocalizedString("lightning__funding_advanced__button2", comment: "")
                            )
                        }
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__funding_advanced__nav_title"))
        .backToWalletButton()
        .background(Color.black)
    }
}

#Preview {
    NavigationStack {
        FundAdvancedOptions()
            .preferredColorScheme(.dark)
    }
}
