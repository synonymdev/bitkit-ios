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
                    title: t("onboarding__tos_checkbox"),
                    subtitle: t("onboarding__tos_checkbox_value"),
                    subtitleUrl: URL(string: Env.termsOfServiceUrl),
                    isChecked: $termsAccepted
                )

                Divider()

                // Privacy checkbox
                CheckboxRow(
                    title: t("onboarding__pp_checkbox"),
                    subtitle: t("onboarding__pp_checkbox_value"),
                    subtitleUrl: URL(string: Env.privacyPolicyUrl),
                    isChecked: $privacyAccepted
                )

                Divider()
            }

            CustomButton(
                title: t("common__continue"),
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
                VStack(alignment: .leading, spacing: 16) {
                    DisplayText(t("onboarding__tos_header"))

                    TosContent()
                        .font(Fonts.regular(size: 17))
                        .foregroundColor(.textSecondary)
                        .padding(.bottom, 300) // Extra padding for keeping it scrollable past footer
                }
                .padding(.top, 48)
            }
            .clipped()

            ScrollViewShadow()

            TermsFooter()
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
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
