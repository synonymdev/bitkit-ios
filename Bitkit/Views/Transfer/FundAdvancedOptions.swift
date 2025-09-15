import SwiftUI

struct FundAdvancedOptions: View {
    @EnvironmentObject private var navigation: NavigationViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__funding_advanced__nav_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    DisplayText(
                        t("lightning__funding_advanced__title"),
                        accentColor: .purpleAccent
                    )
                    .padding(.bottom, 8)

                    BodyMText(t("lightning__funding_advanced__text"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 32)

                    VStack(spacing: 8) {
                        RectangleButton(
                            icon: "scan",
                            title: t("lightning__funding_advanced__button1"),
                            testID: "FundLnUrl"
                        ) {
                            navigation.navigate(.scanner)
                        }

                        RectangleButton(
                            icon: "pencil",
                            title: t("lightning__funding_advanced__button2"),
                            testID: "FundManual"
                        ) {
                            navigation.navigate(.fundManual(nodeUri: nil))
                        }
                    }

                    Spacer()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}

#Preview {
    NavigationStack {
        FundAdvancedOptions()
            .preferredColorScheme(.dark)
    }
}
