import SwiftUI

struct FundAdvancedOptions: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.dismiss) private var dismiss

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
                        NavigationLink(value: Route.scanner) {
                            RectangleButton(
                                icon: Image("scan")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(.purpleAccent),
                                title: t("lightning__funding_advanced__button1")
                            )
                        }

                        RectangleButton(
                            icon: Image("pencil")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .foregroundColor(.purpleAccent),
                            title: t("lightning__funding_advanced__button2")
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
