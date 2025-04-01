//
//  TermsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/11.
//

import SwiftUI

private struct ScrollViewShadow: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color(.clear), Color(.black)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 55)

            Rectangle()
                .fill(Color(.systemBackground))
                // same height as TermsFooter
                .frame(height: 261)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

private struct TermsFooter: View {
    @State private var termsAccepted = false
    @State private var privacyAccepted = false

    var body: some View {
        VStack(spacing: 25) {
            VStack(alignment: .leading, spacing: 12) {
                // Terms checkbox
                CheckboxRow(
                    title: NSLocalizedString("onboarding__tos_checkbox", comment: ""),
                    subtitle: NSLocalizedString("onboarding__tos_checkbox_value", comment: ""),
                    subtitleUrl: URL(string: Env.termsOfServiceUrl),
                    isChecked: $termsAccepted
                )

                Divider()

                // Privacy checkbox
                CheckboxRow(
                    title: NSLocalizedString("onboarding__pp_checkbox", comment: ""),
                    subtitle: NSLocalizedString("onboarding__pp_checkbox_value", comment: ""),
                    subtitleUrl: URL(string: Env.privacyPolicyUrl),
                    isChecked: $privacyAccepted
                )

                Divider()
            }

            CustomButton(
                title: NSLocalizedString("common__continue", comment: ""),
                isDisabled: !(termsAccepted && privacyAccepted),
                destination: IntroView()
            )
        }
        .padding(.top, 16)
        .background(
            Color(.systemBackground)
                .edgesIgnoringSafeArea(.bottom)
        )
    }
}

struct TermsView: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    DisplayText(NSLocalizedString("onboarding__tos_header", comment: ""))

                    TosContent()
                        .font(Fonts.regular(size: 17))
                        .foregroundColor(.textSecondary)
                        .padding(.bottom, 300)  // Extra padding for keeping it scrollable past footer
                }
                .padding(.top, 52)
            }
            .clipped()

            ScrollViewShadow()

            TermsFooter()
        }
        .padding(.horizontal, 32)
        .navigationBarBackButtonHidden(true)
    }
}

#Preview {
    TermsView()
        .preferredColorScheme(.dark)
}

#Preview {
    TermsView()
        .preferredColorScheme(.light)
}
