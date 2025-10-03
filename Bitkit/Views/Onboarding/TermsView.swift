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
    var body: some View {
        VStack(spacing: 25) {
            VStack(alignment: .leading, spacing: 12) {
                FooterItem(
                    title: tTodo("Terms of Use"),
                    subtitle: tTodo("By continuing you declare that you have read and accept the terms of use."),
                    subtitleUrl: nil
                )

                Divider()

                FooterItem(
                    title: t("onboarding__pp_checkbox"),
                    subtitle: tTodo("By continuing you declare that you have read and accept the <accent>privacy policy.</accent>"),
                    subtitleUrl: URL(string: Env.privacyPolicyUrl)
                )

                Divider()
            }

            CustomButton(
                title: t("common__continue"),
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

private struct FooterItem: View {
    let title: String
    let subtitle: String
    let subtitleUrl: URL?

    var body: some View {
        VStack(alignment: .leading) {
            BodyMSBText(title, textColor: .textPrimary)
            BodySSBText(
                subtitle,
                textColor: .textSecondary,
                accentColor: .brandAccent,
                accentAction: {
                    if let url = subtitleUrl {
                        UIApplication.shared.open(url)
                    }
                }
            )
        }
        .padding(.vertical, 3)
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
