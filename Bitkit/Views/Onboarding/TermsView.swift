//
//  TermsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/11.
//

import SwiftUI

struct TappableTextModifier: ViewModifier {
    let url: String

    func body(content: Content) -> some View {
        Button {
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        } label: {
            content
        }
    }
}

struct TermsView: View {
    @State private var termsAccepted = false
    @State private var privacyAccepted = false
    @State private var navigateToIntro = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrolling content
            ScrollView {
                VStack(spacing: 24) {
                    DisplayText(NSLocalizedString("onboarding__tos_header", comment: ""))

                    TosContent()
                        .font(Fonts.regular(size: 17))
                        .foregroundColor(.textPrimary)
                        .padding(.bottom, 300)  // Extra padding for keeping it scrollable past footer
                }
                .padding()
            }
            .background(Color(.systemBackground))

            // Gradient overlay
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [
                        Color(.systemBackground).opacity(0),
                        Color(.systemBackground),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)

                Rectangle()
                    .fill(Color(.systemBackground))
                    .frame(height: 200)
            }
            .frame(maxWidth: .infinity)

            // Footer overlay
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    // Terms checkbox
                    HStack {
                        VStack(alignment: .leading) {
                            SubtitleText(NSLocalizedString("onboarding__tos_checkbox", comment: ""))
                            BodySText(
                                NSLocalizedString("onboarding__tos_checkbox_value", comment: ""),
                                accentColor: .brandAccent,
                                url: URL(string: Env.termsOfServiceUrl)
                            )
                        }

                        Spacer()

                        Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(termsAccepted ? .brandAccent : .textSecondary)
                            .font(.system(size: 32))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        termsAccepted.toggle()
                        Haptics.play(.medium)
                    }

                    Divider()

                    // Privacy checkbox
                    HStack {
                        VStack(alignment: .leading) {
                            SubtitleText(NSLocalizedString("onboarding__pp_checkbox", comment: ""))
                            BodySText(
                                NSLocalizedString("onboarding__pp_checkbox_value", comment: ""),
                                accentColor: .brandAccent,
                                url: URL(string: Env.privacyPolicyUrl)
                            )
                        }

                        Spacer()

                        Image(systemName: privacyAccepted ? "checkmark.square.fill" : "square")
                            .foregroundColor(privacyAccepted ? .brandAccent : .textSecondary)
                            .font(.system(size: 32))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        privacyAccepted.toggle()
                        Haptics.play(.medium)
                    }

                    Divider()
                }
                .padding(.horizontal)

                CustomButton(
                    title: NSLocalizedString("onboarding__get_started", comment: ""),
                    variant: termsAccepted && privacyAccepted ? .primary : .secondary,
                    isDisabled: !(termsAccepted && privacyAccepted)
                ) {
                    if termsAccepted && privacyAccepted {
                        navigateToIntro = true
                    } else {
                        Haptics.notify(.error)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top)
            .padding(.bottom, 20)
            .background(
                Color(.systemBackground)
                    .shadow(radius: 8, y: -4)
                    .edgesIgnoringSafeArea(.bottom)
            )

            NavigationLink(isActive: $navigateToIntro) {
                IntroView()
            } label: {
                EmptyView()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
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
