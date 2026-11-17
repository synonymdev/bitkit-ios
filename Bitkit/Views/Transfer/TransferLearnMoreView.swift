import SwiftUI

struct TransferLearnMoreView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        DisplayText(t("lightning__spark_learn__title"), accentColor: .purpleAccent)

                        VStack(alignment: .leading, spacing: 0) {
                            BodyMBoldText(t("fee__fast__title"))
                            BodyMText(t("lightning__spark_learn__fast_text"))
                                .padding(.bottom, 22)
                            BodyMBoldText(t("lightning__spending_confirm__later"))
                            BodyMText(t("lightning__spark_learn__later_text"))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        DisplayText(t("lightning__spark_learn__about_title"), accentColor: .purpleAccent)
                        BodyMText(t("lightning__spark_learn__about_text"))
                    }
                }
                .padding(.bottom, 16)
            }

            CustomButton(title: t("common__understood")) {
                dismiss()
            }
            .padding(.top, 16)
            .accessibilityIdentifier("LiquidityContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        TransferLearnMoreView()
    }
    .preferredColorScheme(.dark)
}
